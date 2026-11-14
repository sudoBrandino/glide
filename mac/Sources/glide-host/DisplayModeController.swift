import AppKit
import CoreGraphics
import GlideCore

// DisplaySettings (host.json "display") lives in GlideCore/ModeRestore.swift.

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
    /// A restore is waiting for its display to come back online (lid closed, unplugged).
    private var awaitingDisplay = false
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
    /// Longest wait for the virtual display before a session starts anyway: leftover removal (3 s),
    /// coming online (4 s), read-back with one re-apply (4 s) and the child probe (3 s).
    static let virtualDisplayTimeout: TimeInterval = 16

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
                // Matched by identity: display IDs are reused after a reboot or replug.
                let on: String
                switch restoreDestination() {
                case let .display(id): on = " on display \(id)"
                case .notConnected: on = " (its display isn't connected; restored when it is)"
                case .served: on = ""
                }
                log("display: pending restore to \(r)\(on) from a previous run (in \(Int(Self.startupRestoreGrace))s unless a viewer connects)")
                scheduleRestore(after: Self.startupRestoreGrace, reason: "previous run")
            }
        }
    }

    // MARK: Session hooks (any thread)

    /// A viewer authenticated. Switches the mode if the policy says so, then calls `then` (on main)
    /// once the display has settled.
    func sessionBegan(id: Int, viewW: Int, viewH: Int, viewerHz: Int, then: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            pendingRestore?.cancel(); pendingRestore = nil
            viewDebounce?.cancel(); viewDebounce = nil
            owner = id
            sessionPreference = nil
            userOverride = false
            viewer = (viewW, viewH)
            // The virtual display (on by default) is created first, sized to this viewer's pixels
            // and refresh rate; once it is online it is `displayID` and the policy below applies to
            // it like to any display.
            // Answered once: by the virtual display, or by the fallback timeout if it never answers
            // (the session must start streaming either way).
            var answered = false
            let proceed = { [self] in
                guard !answered else { return }
                answered = true
                guard owner == id else { return }
                trackedDisplay = displayID
                tracker.reset(current: currentMode())
                if settings.restore != nil, case let .display(rd) = restoreDestination(), rd != displayID {
                    // Left by a session that streamed another display (§3.5): that display isn't watched now.
                    if settings.restoreEnabled { restore(reason: "display \(rd) not streamed now") } else { setRestoreTarget(nil) }
                }
                if applyPolicy(reason: "viewer connected") { waitForSettle(then) } else { then() }
            }
            VirtualDisplayManager.shared.sessionBegan(viewerHz: viewerHz) { _ in proceed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.virtualDisplayTimeout) {
                guard !answered else { return }
                log("display: the virtual display didn't answer within \(Int(Self.virtualDisplayTimeout)) s; starting the session with display \(ActiveDisplay.current())")
                proceed()
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

    /// Restore the pre-Glide mode immediately (menu action). Mid-session this also stops
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

    private func scheduleRestore(after: TimeInterval, reason: String, evenInSession: Bool = false) {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, evenInSession || self.owner == nil else { return }
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

    /// A monitor is about to mirror the virtual display (macOS gives a mirror slave a matching
    /// mode): remember its own mode, persisted, so it comes back even after a crash (startup restore).
    /// A restore already pending for this monitor is never overwritten: it holds the monitor's real
    /// mode, and the current one may already be Glide's (an earlier mirror whose restore failed or
    /// is still due, or a switch while the display was created).
    func rememberBeforeMirror(_ display: CGDirectDisplayID) {
        loadSettings()
        switch ModeRestore.beforeMirror(pending: settings.restore == nil ? nil : restoreDestination(), display: display, served: displayID) {
        case .keepPending:
            log("display: display \(display) mirrors the virtual display; keeping its saved mode \(settings.restore.map { "\($0)" } ?? "?")")
        case .otherPending:
            log("display: display \(display) mirrors the virtual display; not saving its mode (a restore for another display is pending)")
        case .remember:
            guard let m = currentMode(of: display) else { return }
            awaitingDisplay = false
            persist { $0.restore = m; $0.restoreDisplay = display; $0.restoreIdentity = Self.identity(of: display) }
            log("display: remembering display \(display)'s mode \(m) @ \(Int(m.refreshRate.rounded())) Hz while it mirrors the virtual display")
        }
    }

    /// The mode remembered for `display` (rememberBeforeMirror or an earlier switch), if any.
    func rememberedMode(of display: CGDirectDisplayID) -> DisplayModeInfo? {
        restoreDestination() == .display(display) ? settings.restore : nil
    }

    /// The mirror ended: give the monitor its own mode back if macOS didn't (this is the user's
    /// mode, so it is restored regardless of "restore on disconnect").
    func restoreAfterMirror(_ display: CGDirectDisplayID) {
        guard settings.restore != nil else { return }
        switch restoreDestination() {
        case let .display(id) where id == display: restore(reason: "mirror ended")
        case .notConnected: restore(reason: "mirror ended")  // went offline while mirroring: restored when it is back
        default: return
        }
    }

    /// Quit, Restart, SIGTERM, SIGINT, after `VirtualDisplayManager.shutdown` (which ended the
    /// mirror of `unmirrored`, if any): restores the saved mode now, synchronously, because the
    /// process exits right after. A monitor that just stopped mirroring first gets the time macOS
    /// takes to give it a mode of its own (else macOS undoes the restore); the wait is bounded.
    func restoreBeforeExit(reason: String, unmirrored: (display: CGDirectDisplayID, at: TimeInterval)?) {
        loadSettings()
        pendingRestore?.cancel(); pendingRestore = nil
        guard settings.restore != nil else { return }
        if let u = unmirrored, restoreDestination() == .display(u.display) {
            let wait = min(ModeRestore.afterMirrorSettle, max(0, u.at + ModeRestore.afterMirrorSettle - ProcessInfo.processInfo.systemUptime))
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }  // not the run loop: nothing else may run while exiting
        }
        restore(reason: reason)
    }

    /// `display` currently mirrors Glide's virtual display: its mode follows the mirror, so a
    /// restore must wait for the mirror to end (VirtualDisplayManager calls restoreAfterMirror).
    private func heldByMirror(_ display: CGDirectDisplayID) -> Bool {
        if VirtualDisplayManager.shared.mirroredPhysical == display { return true }
        guard let v = ActiveDisplay.virtualDisplay else { return false }
        return CGDisplayMirrorsDisplay(display) == v
    }

    /// Where the saved restore applies now, by identity (display IDs are reused after a reboot or
    /// a replug; files without an identity use the saved ID).
    private func restoreDestination() -> ModeRestore.Target {
        ModeRestore.resolve(identity: settings.restoreIdentity, legacyID: settings.restoreDisplay, online: Self.onlineIdentities())
    }

    /// The resolved display, or the served one for files written before multi-display support.
    private func restoreTargetID() -> CGDirectDisplayID? {
        switch restoreDestination() {
        case let .display(id): return id
        case .served: return displayID
        case .notConnected: return nil
        }
    }

    private func restore(reason: String) {
        pendingRestore?.cancel(); pendingRestore = nil
        guard let r = settings.restore else { return }
        // The display Glide switched, which need not be the one served now (§3.5 selection).
        guard let target = restoreTargetID() else {
            // Kept (persisted) until the display is back: restored then, or at the next start.
            awaitingDisplay = true
            log("display: display for the saved mode \(r) isn't connected; restoring it when it is back"); return
        }
        if ActiveDisplay.isVirtual(target) {  // a saved mode belongs to a physical display
            setRestoreTarget(nil)
            log("display: not restoring \(r) onto the virtual display; dropped"); return
        }
        guard ActiveDisplay.isOnline(target) else {
            awaitingDisplay = true
            log("display: display \(target) is offline; restoring \(r) when it is back"); return
        }
        if heldByMirror(target) { log("display: display \(target) mirrors the virtual display; restoring \(r) when the mirror ends"); return }
        awaitingDisplay = false
        setRestoreTarget(nil)
        let all = modes(of: target)
        switch ModeRestore.choose(saved: r, current: currentMode(of: target), available: all.map(\.info)) {
        case .alreadyThere:
            return
        case .unavailable:
            log("display: can't restore \(r) on display \(target): mode no longer available")
        case let .switchTo(m):
            guard let mode = all.first(where: { $0.info == m })?.mode else { return }
            let ok = configure(mode, on: target, from: currentMode(of: target))
            let rate = ModeRestore.sameRate(m.refreshRate, r.refreshRate) ? "" : " (\(Int(r.refreshRate.rounded())) Hz is gone; \(Int(m.refreshRate.rounded())) Hz)"
            lastAction = "\(ok ? "restored" : "FAILED to restore") \(m) @ \(Int(m.refreshRate.rounded())) Hz\(rate)\(target != displayID ? " on display \(target)" : "") (\(reason))"
            log("display: " + lastAction!)
        }
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
            let target = restoreDestination()
            let rd: CGDirectDisplayID? = target == .served ? old : { if case let .display(id) = target { return id }; return nil }()
            if let rd, rd != displayID {
                if owner != nil && settings.restoreEnabled && ActiveDisplay.isOnline(rd) {
                    restore(reason: "display \(rd) no longer streamed")
                } else if owner != nil && ActiveDisplay.isOnline(rd) {
                    log("display: dropping pending restore (it was for display \(rd))")
                    pendingRestore?.cancel(); pendingRestore = nil
                    setRestoreTarget(nil)
                }  // else: no viewer, and the pending restore (grace period) still handles display rd;
                   // or display rd is offline: kept until it is back (screenParametersChanged)
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
        // The display a saved mode belongs to is back (lid opened, replugged): restore it once it settled.
        if awaitingDisplay, settings.restore != nil, case let .display(t) = restoreDestination(), ActiveDisplay.isOnline(t),
           !heldByMirror(t), owner == nil || t != displayID {
            awaitingDisplay = false
            log("display: display \(t) is back; restoring its saved mode")
            scheduleRestore(after: ModeRestore.afterMirrorSettle, reason: "display \(t) is back", evenInSession: owner != nil)
        }
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
        // A monitor mirroring the virtual display keeps its remembered mode until the mirror ends.
        if m == nil, let rd = restoreTargetID(), heldByMirror(rd) { return }
        let d = m == nil ? nil : UInt32(trackedDisplay)
        let ident = d.map(Self.identity(of:))
        guard settings.restore != m || settings.restoreDisplay != d || settings.restoreIdentity != ident else { return }
        if m == nil { awaitingDisplay = false }
        persist { $0.restore = m; $0.restoreDisplay = d; $0.restoreIdentity = ident }
    }

    /// The §3.5 identity a saved mode is matched by (the name is informational).
    static func identity(of id: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                        name: ActiveDisplay.descriptor(id)?.name ?? "")
    }

    /// Every online display except Glide's virtual ones, mirrored ones included (a monitor that
    /// mirrors the virtual display is still the display a saved mode belongs to).
    static func onlineIdentities() -> [DisplayIdentity] {
        VirtualDisplayManager.physicalDisplays(excluding: nil).map {
            DisplayIdentity(id: $0, vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0), name: "")
        }
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

/// Quit, Restart, SIGTERM and SIGINT (main thread): end the mirror and remove the virtual display
/// first, then give the monitor its own mode back synchronously, so the restore isn't deferred
/// behind a mirror that is about to end, nor lost to the exit that follows. Clears host.json
/// `display.restore` once restored.
func restoreDisplaysBeforeExit(reason: String) {
    let unmirrored = VirtualDisplayManager.shared.shutdown(reason: reason)
    DisplayModeController.shared.restoreBeforeExit(reason: reason, unmirrored: unmirrored)
}

extension DisplayModeInfo {
    init(_ m: CGDisplayMode) {
        self.init(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refreshRate: m.refreshRate)
    }
}
