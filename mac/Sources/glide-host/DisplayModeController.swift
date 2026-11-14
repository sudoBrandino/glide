import AppKit
import CoreGraphics
import GlideCore

/// Display settings persisted in host.json under "display". Stored as strings and parsed leniently:
/// a typo must never make host.json undecodable (HostConfig.load would then fall back to defaults).
struct DisplaySettings: Codable, Equatable {
    /// automatic | crisp | smooth | retina | manual (default automatic)
    var mode: String?
    /// What automatic picks for 4K-class viewers: retina (looks like 1920x1080) | smooth (looks like 2560x1440)
    var highDPIViewer: String?
    /// Restore the pre-session display mode when the viewer disconnects (default true).
    var restoreOnDisconnect: Bool?
    /// The mode to restore (set when Glide first switches the mode; cleared once restored).
    var restore: DisplayModeInfo?

    var preference: DisplayModePreference { mode.flatMap { DisplayModePreference(rawValue: $0.lowercased()) } ?? .automatic }
    var highDPIChoice: HighDPIViewerChoice { highDPIViewer.flatMap { HighDPIViewerChoice(rawValue: $0.lowercased()) } ?? .retina }
    var restoreEnabled: Bool { restoreOnDisconnect ?? true }
}

extension HostConfig {
    /// Read-modify-write of host.json that refuses to write if the file can't be decoded
    /// (HostConfig.load() would otherwise replace it with a fresh salt).
    static func modify(_ f: (inout HostConfig) -> Void) {
        guard let d = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(HostConfig.self, from: d) else {
            log("display: host.json unreadable; not saving display settings"); return
        }
        f(&c)
        c.save()
    }
}

/// Switches the Mac's display mode to suit the viewer (CGConfigureDisplayWithDisplayMode) and restores
/// it afterwards. All state lives on the main queue.
///
/// Sequencing: on connect the mode is switched *before* capture starts (one capture, one ServerHello).
/// Mid-session (ViewSize, menu change) the switch fires NSApplication.didChangeScreenParameters and
/// Session's existing observer re-captures once -> VideoConfig + keyframe.
/// Never fights the user: if the mode changes behind our back during a session, auto-switching stops
/// until the next session and the mode is not restored.
final class DisplayModeController: @unchecked Sendable {
    static let shared = DisplayModeController()

    /// Resolved on every use (ActiveDisplay): the lid closing or a monitor swap changes it.
    var displayID: CGDirectDisplayID { ActiveDisplay.current() }
    /// The display the tracker's modes belong to; a different one is a new display, not a manual change.
    private var trackedDisplay: CGDirectDisplayID = 0
    private(set) var settings = DisplaySettings()
    private var loaded = false
    private var started = false
    private var owner: Int?                    // session currently driving the policy
    /// Preference chosen by the owning session's viewer (SetDisplayPreference, PROTOCOL.md §3.3).
    /// Overrides `settings.preference` until the session ends or the menu bar changes the policy.
    private(set) var sessionPreference: DisplayModePreference?
    private var viewer: (w: Int, h: Int)?
    private(set) var userOverride = false
    /// Tells our own switches from the user's (GlideCore, unit-tested in glide-selftest).
    private var tracker = DisplayChangeTracker(current: nil)
    /// A screen-parameters notification arrived since the last switch began (it can arrive
    /// re-entrantly, before CGCompleteDisplayConfiguration returns).
    private var notifiedSinceSwitch = false
    private var pendingRestore: DispatchWorkItem?
    private var viewDebounce: DispatchWorkItem?
    private var settleWaiters: [() -> Void] = []
    /// Human-readable last action, for the menu.
    private(set) var lastAction: String?

    /// Posted (main queue) when the effective preference changes; sessions re-send DisplayInfo.
    static let preferenceChanged = Notification.Name("GlideDisplayPreferenceChanged")

    /// The preference in force: the viewer's per-session choice, else the persisted policy.
    var effectivePreference: DisplayModePreference { sessionPreference ?? settings.preference }

    static let restoreGrace: TimeInterval = 10      // reconnects within this keep the mode
    static let startupRestoreGrace: TimeInterval = 30
    static let viewSizeDebounce: TimeInterval = 0.6

    // MARK: Setup

    /// Loads settings without side effects (also used by --selftest-ui).
    func loadSettings() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: HostConfig.url), let c = try? JSONDecoder().decode(HostConfig.self, from: d) {
            settings = c.display ?? DisplaySettings()
        }
    }

    func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true
            loadSettings()
            trackedDisplay = displayID
            tracker.reset(current: currentMode())
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screenParametersChanged()
            }
            log("display: policy \(settings.preference.rawValue) (4K viewers: \(settings.highDPIChoice.rawValue)), restore on disconnect \(settings.restoreEnabled ? "on" : "off"), current \(tracker.expected.map { "\($0)" } ?? "?")")
            if let r = settings.restore {
                // Left over from a previous run (crash/update mid-session). A reconnecting viewer cancels this.
                log("display: pending restore to \(r) from a previous run (in \(Int(Self.startupRestoreGrace))s unless a viewer connects)")
                scheduleRestore(after: Self.startupRestoreGrace, reason: "previous run")
            }
        }
    }

    // MARK: Session hooks (any thread)

    /// A viewer authenticated. Switches the mode if the policy says so, then calls `then` (on main)
    /// once the display has settled.
    func sessionBegan(id: Int, viewW: Int, viewH: Int, then: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            pendingRestore?.cancel(); pendingRestore = nil
            viewDebounce?.cancel(); viewDebounce = nil
            owner = id
            sessionPreference = nil
            userOverride = false
            viewer = (viewW, viewH)
            trackedDisplay = displayID
            tracker.reset(current: currentMode())
            if applyPolicy(reason: "viewer connected") { waitForSettle(then) } else { then() }
        }
    }

    /// The viewer's view size changed. Debounced; `then(switched)` runs on main with whether the mode
    /// was switched (if so, Session's display-change observer performs the re-capture).
    func viewSizeChanged(id: Int, viewW: Int, viewH: Int, then: @escaping (_ switched: Bool) -> Void) {
        DispatchQueue.main.async { [self] in
            guard owner == id else { then(false); return }
            viewer = (viewW, viewH)
            viewDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.owner == id else { return }
                self.viewDebounce = nil
                then(self.applyPolicy(reason: "viewer view size \(viewW)x\(viewH)"))
            }
            viewDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.viewSizeDebounce, execute: work)
        }
    }

    func sessionEnded(id: Int) {
        DispatchQueue.main.async { [self] in
            guard owner == id else { return }
            owner = nil
            sessionPreference = nil
            viewer = nil
            viewDebounce?.cancel(); viewDebounce = nil
            guard settings.restore != nil else { return }
            if settings.restoreEnabled && !userOverride {
                scheduleRestore(after: Self.restoreGrace, reason: "viewer disconnected")
            } else {
                setRestoreTarget(nil)  // keep whatever mode is current
            }
        }
    }

    // MARK: Menu actions (main thread)

    var sessionActive: Bool { owner != nil }
    var restoreTarget: DisplayModeInfo? { settings.restore }

    func setPreference(_ p: DisplayModePreference) {
        persist { $0.mode = p.rawValue }
        sessionPreference = nil  // the Mac user's explicit choice wins over the viewer's
        userOverride = false
        log("display: policy set to \(p.rawValue)")
        _ = applyPolicy(reason: "policy changed to \(p.rawValue)")
        NotificationCenter.default.post(name: Self.preferenceChanged, object: nil)
    }

    /// The viewer of session `id` picked a preference for this session (not persisted). Applied
    /// immediately; `then(switched)` runs on main. If the mode switched, Session's display-change
    /// observer re-captures.
    func setSessionPreference(id: Int, _ p: DisplayModePreference, then: @escaping (_ switched: Bool) -> Void) {
        DispatchQueue.main.async { [self] in
            guard owner == id else { then(false); return }
            sessionPreference = p
            userOverride = false
            log("display: viewer chose \(p.rawValue) for this session")
            let switched = applyPolicy(reason: "viewer chose \(p.rawValue)")
            NotificationCenter.default.post(name: Self.preferenceChanged, object: nil)
            then(switched)
        }
    }

    func setHighDPIChoice(_ c: HighDPIViewerChoice) {
        persist { $0.highDPIViewer = c.rawValue }
        userOverride = false
        log("display: 4K viewers -> \(c.rawValue)")
        _ = applyPolicy(reason: "4K choice changed to \(c.rawValue)")
        NotificationCenter.default.post(name: Self.preferenceChanged, object: nil)
    }

    func setRestoreOnDisconnect(_ on: Bool) { persist { $0.restoreOnDisconnect = on } }

    /// Restore the pre-Glide mode immediately (menu action / quitting). Mid-session this also stops
    /// auto-switching for the rest of the session.
    func restoreNow(reason: String) {
        if owner != nil { userOverride = true }
        restore(reason: reason)
    }

    /// What the policy would pick for the current viewer (for the menu).
    func describeChoice() -> String? {
        guard let v = viewer else { return nil }
        let style = DisplayModePolicy.resolve(effectivePreference, viewerW: v.w, viewerH: v.h, highDPIChoice: settings.highDPIChoice)
        guard let m = DisplayModePolicy.choose(preference: effectivePreference, viewerW: v.w, viewerH: v.h, modes: modes().map(\.info), current: currentMode(), highDPIChoice: settings.highDPIChoice) else { return nil }
        return "\(style.rawValue): \(m)"
    }

    // MARK: Core

    /// Applies the policy for the current viewer. Returns true if the mode was switched.
    private func applyPolicy(reason: String) -> Bool {
        guard owner != nil, let v = viewer else { return false }
        if userOverride { log("display: not switching (\(reason)) — mode was changed manually this session"); return false }
        let all = modes()
        let cur = currentMode()
        guard let target = DisplayModePolicy.choose(preference: effectivePreference, viewerW: v.w, viewerH: v.h,
                                                    modes: all.map(\.info), current: cur, highDPIChoice: settings.highDPIChoice) else { return false }
        if let cur, target.sameSize(cur) { return false }
        guard let mode = all.first(where: { $0.info == target })?.mode else { return false }
        if settings.restore == nil, let cur { setRestoreTarget(cur) }
        let ok = configure(mode, from: cur)
        let msg = "\(ok ? "switched" : "FAILED to switch") \(cur.map { "\($0)" } ?? "?") -> \(target) for viewer \(v.w)x\(v.h) (\(effectivePreference.rawValue)\(sessionPreference != nil ? " [viewer]" : ""); \(reason))"
        log("display: " + msg)
        lastAction = msg
        return ok
    }

    private func scheduleRestore(after: TimeInterval, reason: String) {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.owner == nil else { return }
            self.pendingRestore = nil
            self.restore(reason: reason)
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }

    private func restore(reason: String) {
        pendingRestore?.cancel(); pendingRestore = nil
        guard let r = settings.restore else { return }
        setRestoreTarget(nil)
        if let cur = currentMode(), cur.sameSize(r) { return }
        guard let mode = modes().first(where: { $0.info.sameSize(r) })?.mode else {
            log("display: can't restore \(r): mode no longer available"); return
        }
        let ok = configure(mode, from: currentMode())
        lastAction = "\(ok ? "restored" : "FAILED to restore") \(r) (\(reason))"
        log("display: " + lastAction!)
    }

    private func configure(_ mode: CGDisplayMode, from: DisplayModeInfo?) -> Bool {
        // Record the switch first: the screen-parameters notification can be delivered re-entrantly
        // inside CGCompleteDisplayConfiguration, before it returns.
        tracker.willSwitch(from: from, to: DisplayModeInfo(mode), now: ProcessInfo.processInfo.systemUptime)
        notifiedSinceSwitch = false
        var cfg: CGDisplayConfigRef?
        var ok = CGBeginDisplayConfiguration(&cfg) == .success
        if ok {
            CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
            // forSession: an automatic change never outlives the login session (the user's own
            // permanent choice comes back after logout/reboot).
            ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        }
        tracker.didSwitch(ok: ok, actual: currentMode(), now: ProcessInfo.processInfo.systemUptime)
        return ok
    }

    private func screenParametersChanged() {
        if !settleWaiters.isEmpty {
            let w = settleWaiters; settleWaiters = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { w.forEach { $0() } }
        }
        notifiedSinceSwitch = true
        if displayID != trackedDisplay {
            // Lid closed/opened or monitor swapped: modes of the old display mean nothing here.
            let old = trackedDisplay
            trackedDisplay = displayID
            tracker.reset(current: currentMode())
            log("display: now serving display \(displayID) (was \(old)), current \(currentMode().map { "\($0)" } ?? "?")")
            if settings.restore != nil {
                log("display: dropping pending restore (it was for display \(old))")
                pendingRestore?.cancel(); pendingRestore = nil
                setRestoreTarget(nil)
            }
            // A viewer is connected: give the new display the mode the policy wants for it.
            if owner != nil && !userOverride { _ = applyPolicy(reason: "display changed") }
            return
        }
        guard let cur = currentMode(),
              tracker.observe(current: cur, now: ProcessInfo.processInfo.systemUptime) == .manual,
              owner != nil || settings.restore != nil else { return }
        if owner != nil {
            userOverride = true
            lastAction = "mode changed manually to \(cur); auto-switching paused until the next session"
            log("display: " + lastAction!)
        } else {
            log("display: mode changed manually to \(cur); dropping pending restore")
        }
        pendingRestore?.cancel(); pendingRestore = nil
        setRestoreTarget(nil)
    }

    /// Calls `then` once the screen-parameters notification for a switch arrived (+300 ms), or after 2.5 s.
    private func waitForSettle(_ then: @escaping () -> Void) {
        var done = false
        let once = { if !done { done = true; then() } }
        if notifiedSinceSwitch {  // already delivered (re-entrantly, during the switch)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { once() }
            return
        }
        settleWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { once() }
    }

    private func setRestoreTarget(_ m: DisplayModeInfo?) {
        guard settings.restore != m else { return }
        persist { $0.restore = m }
    }

    private func persist(_ f: (inout DisplaySettings) -> Void) {
        loadSettings()
        f(&settings)
        let s = settings
        HostConfig.modify { $0.display = s }
    }

    // MARK: CoreGraphics

    struct Mode { let mode: CGDisplayMode; let info: DisplayModeInfo }

    func modes() -> [Mode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
        return all.filter { $0.isUsableForDesktopGUI() }.map { Mode(mode: $0, info: DisplayModeInfo($0)) }
    }

    func currentMode() -> DisplayModeInfo? { CGDisplayCopyDisplayMode(displayID).map(DisplayModeInfo.init) }
}

extension DisplayModeInfo {
    init(_ m: CGDisplayMode) {
        self.init(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshRate: m.refreshRate)
    }
}
