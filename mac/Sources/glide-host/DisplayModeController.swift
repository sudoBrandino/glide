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
    /// The display `restore` belongs to (nil in files written before multi-display support: the
    /// display being served).
    var restoreDisplay: UInt32?

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

    /// Resolved on every use (ActiveDisplay): the session's selected display (PROTOCOL.md §3.5), the
    /// lid closing or a monitor swap changes it.
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
            // The virtual display (if enabled) is created first, sized to this viewer; once it is
            // online it is `displayID` and the policy below applies to it like to any display.
            VirtualDisplayManager.shared.sessionBegan { [self] _ in
                guard owner == id else { return }
                trackedDisplay = displayID
                tracker.reset(current: currentMode())
                if settings.restore != nil, let rd = settings.restoreDisplay, rd != displayID {
                    // Left by a session that streamed another display (§3.5): that display isn't watched now.
                    if settings.restoreEnabled && ActiveDisplay.isOnline(rd) { restore(reason: "display \(rd) not streamed now") } else { setRestoreTarget(nil) }
                }
                if applyPolicy(reason: "viewer connected") { waitForSettle(then) } else { then() }
            }
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
            VirtualDisplayManager.shared.sessionEnded()
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
    /// The connected viewer's view size (pixels), if a session is active.
    var viewerSize: (w: Int, h: Int)? { viewer.map { (w: $0.w, h: $0.h) } }
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

    /// The session's selected display changed (SelectDisplay / menu bar, §3.5). Gives the previous
    /// display its pre-session mode back, applies the policy to the new one and calls
    /// `then(switched)` on main once the display has settled. If the mode switched, Session's
    /// display-change observer re-captures as well.
    func servedDisplayChanged(then: @escaping (_ switched: Bool) -> Void) {
        DispatchQueue.main.async { [self] in
            guard displayID != trackedDisplay else { then(false); return }
            if followServedDisplay(reason: "display selected") { waitForSettle { then(true) } } else { then(false) }
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
        if ActiveDisplay.isVirtual(displayID) { return VirtualDisplayManager.shared.plan.map { "virtual display \($0)" } }
        let style = DisplayModePolicy.resolve(effectivePreference, viewerW: v.w, viewerH: v.h, highDPIChoice: settings.highDPIChoice)
        guard let m = DisplayModePolicy.choose(preference: effectivePreference, viewerW: v.w, viewerH: v.h, modes: modes().map(\.info), current: currentMode(), highDPIChoice: settings.highDPIChoice) else { return nil }
        return "\(style.rawValue): \(m)"
    }

    // MARK: Core

    /// Applies the policy for the current viewer. Returns true if the mode was switched.
    private func applyPolicy(reason: String) -> Bool {
        guard owner != nil, let v = viewer else { return false }
        if ActiveDisplay.isVirtual(displayID) {
            // Never CGConfigureDisplayWithDisplayMode a virtual display (VirtualDisplay.swift):
            // re-apply its own settings instead.
            let switched = VirtualDisplayManager.shared.applyPolicy(reason: reason)
            if switched { lastAction = "virtual display: " + (VirtualDisplayManager.shared.lastAction ?? "reconfigured") }
            return switched
        }
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

    /// The virtual display is about to take over: put the physical display back into the mode it
    /// had before Glide switched it (while it is still `displayID`).
    func restorePhysicalBeforeVirtual() {
        guard settings.restore != nil, !ActiveDisplay.isVirtual(displayID) else { return }
        restore(reason: "virtual display takes over")
    }

    private func restore(reason: String) {
        pendingRestore?.cancel(); pendingRestore = nil
        guard let r = settings.restore else { return }
        // The display Glide switched, which need not be the one served now (§3.5 selection).
        let target = settings.restoreDisplay ?? displayID
        setRestoreTarget(nil)
        if ActiveDisplay.isVirtual(target) {  // a saved mode belongs to a physical display
            log("display: not restoring \(r) onto the virtual display; dropped"); return
        }
        guard ActiveDisplay.isOnline(target) else { log("display: can't restore \(r): display \(target) is offline"); return }
        if let cur = currentMode(of: target), cur.sameSize(r) { return }
        guard let mode = modes(of: target).first(where: { $0.info.sameSize(r) })?.mode else {
            log("display: can't restore \(r) on display \(target): mode no longer available"); return
        }
        let ok = configure(mode, on: target, from: currentMode(of: target))
        lastAction = "\(ok ? "restored" : "FAILED to restore") \(r)\(target != displayID ? " on display \(target)" : "") (\(reason))"
        log("display: " + lastAction!)
    }

    private func configure(_ mode: CGDisplayMode, on display: CGDirectDisplayID? = nil, from: DisplayModeInfo?) -> Bool {
        let display = display ?? displayID
        // The tracker follows the served display only; restoring another display isn't a change here.
        let tracked = display == trackedDisplay
        // Record the switch first: the screen-parameters notification can be delivered re-entrantly
        // inside CGCompleteDisplayConfiguration, before it returns.
        if tracked {
            tracker.willSwitch(from: from, to: DisplayModeInfo(mode), now: ProcessInfo.processInfo.systemUptime)
            notifiedSinceSwitch = false
        }
        var cfg: CGDisplayConfigRef?
        var ok = CGBeginDisplayConfiguration(&cfg) == .success
        if ok {
            CGConfigureDisplayWithDisplayMode(cfg, display, mode, nil)
            // forSession: an automatic change never outlives the login session (the user's own
            // permanent choice comes back after logout/reboot).
            ok = CGCompleteDisplayConfiguration(cfg, .forSession) == .success
        }
        if tracked { tracker.didSwitch(ok: ok, actual: currentMode(of: display), now: ProcessInfo.processInfo.systemUptime) }
        return ok
    }

    /// The served display changed (selection, lid, monitor swap): the tracker's modes belong to the
    /// old display. Gives the old display its pre-session mode back while a viewer is connected
    /// (it is no longer being watched), then applies the policy to the new one. Returns true if
    /// the new display's mode was switched.
    private func followServedDisplay(reason: String) -> Bool {
        let old = trackedDisplay
        trackedDisplay = displayID
        // A manual change on the old display says nothing about this one.
        userOverride = false
        log("display: now serving display \(displayID) (was \(old)), current \(currentMode().map { "\($0)" } ?? "?")")
        if settings.restore != nil {
            let rd = settings.restoreDisplay ?? old
            if rd != displayID {
                if owner != nil && settings.restoreEnabled && ActiveDisplay.isOnline(rd) {
                    restore(reason: "display \(rd) no longer streamed")
                } else if owner != nil || !ActiveDisplay.isOnline(rd) {
                    log("display: dropping pending restore (it was for display \(rd))")
                    pendingRestore?.cancel(); pendingRestore = nil
                    setRestoreTarget(nil)
                }  // else: no viewer, and the pending restore (grace period) still handles display rd
            }
        }
        tracker.reset(current: currentMode())
        guard owner != nil else { return false }
        return applyPolicy(reason: reason)
    }

    private func screenParametersChanged() {
        if !settleWaiters.isEmpty {
            let w = settleWaiters; settleWaiters = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { w.forEach { $0() } }
        }
        notifiedSinceSwitch = true
        if displayID != trackedDisplay {
            // Lid closed/opened, monitor swapped or the selected display went away/came back:
            // modes of the old display mean nothing here.
            _ = followServedDisplay(reason: "display changed")
            return
        }
        // Our own virtual display changes mode only when Glide re-applies its settings; there is no
        // user mode to track (and CoreGraphics reports no modes for it to this process).
        if ActiveDisplay.isVirtual(displayID) { tracker.reset(current: currentMode()); return }
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
        let d = m == nil ? nil : UInt32(trackedDisplay)
        guard settings.restore != m || settings.restoreDisplay != d else { return }
        persist { $0.restore = m; $0.restoreDisplay = d }
    }

    private func persist(_ f: (inout DisplaySettings) -> Void) {
        loadSettings()
        f(&settings)
        let s = settings
        HostConfig.modify { $0.display = s }
    }

    // MARK: CoreGraphics

    struct Mode { let mode: CGDisplayMode; let info: DisplayModeInfo }

    func modes(of display: CGDirectDisplayID? = nil) -> [Mode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(display ?? displayID, opts) as? [CGDisplayMode]) ?? []
        return all.filter { $0.isUsableForDesktopGUI() }.map { Mode(mode: $0, info: DisplayModeInfo($0)) }
    }

    func currentMode(of display: CGDirectDisplayID? = nil) -> DisplayModeInfo? {
        ActiveDisplay.mode(of: display ?? displayID)
    }
}

extension DisplayModeInfo {
    init(_ m: CGDisplayMode) {
        self.init(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshRate: m.refreshRate)
    }
}
