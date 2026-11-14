import AppKit
import CGlideVirtualDisplay
import CoreGraphics
import GlideCore

/// The virtual display (docs/VIRTUAL_DISPLAY.md): a CGVirtualDisplay sized to the viewer's pixels
/// and refresh rate, which Glide streams 1:1 instead of the physical screen. Glide's default path.
///
/// - On by default (host.json `"virtualDisplay": {"enabled": false}` or the menu bar opts out; a
///   `--display` pin also turns the default off).
/// - One display per host process at a time: created when a viewer connects (or at launch with
///   `lifetime: always`), resized by re-applying its own settings (never re-created for a new size
///   within the generous 6K limits), removed only when idle and only while the displays are awake.
///   macOS defers a virtual display's removal while every display sleeps ("non-wake state"): it
///   then lingers, even past process exit, until the next display wake.
/// - With a monitor attached the monitor mirrors the virtual display while a viewer is connected
///   (`whenMonitorAttached`, default "mirror"): one desktop, every window visible to the viewer.
///   The arrangement is restored on disconnect; every change is `.forSession`.
/// - Its mode is never switched with CGConfigureDisplayWithDisplayMode, only by re-applying its own
///   single-mode settings. The creating process gets no CoreGraphics mode for its own virtual
///   display (and AppKit doesn't list it), so Glide reads the result back from CGDisplayBounds and
///   a child process (`glide-host --list-display-modes ID`).
/// - Fails safe: if the private API is missing or creation fails, it logs, shows it in the menu,
///   and Glide serves the physical display as before.
///
/// All state is main-queue confined.
final class VirtualDisplayManager: @unchecked Sendable {
    static let shared = VirtualDisplayManager()

    static let displayName = "Glide Virtual Display"
    /// Arbitrary non-zero IDs (macOS 14+ wants a vendor ID). A stable vendor/product/serial is one
    /// "monitor" to macOS, so its arrangement is remembered across sessions.
    static let vendorID: UInt32 = 0x676C   // "gl"
    static let productID: UInt32 = 0x7664  // "vd"
    /// Serial 1 normally; 2 if a leftover display with serial 1 is still pending removal (macOS
    /// refuses a second display with the same identity: "no displayID available").
    static let serialNumbers: [UInt32] = [1, 2]
    static let onlineTimeout: TimeInterval = 4

    /// How the virtual display sits among the Mac's displays (GlideCore, unit-tested).
    typealias Arrangement = VirtualDisplayLayout
    /// Display changes come in bursts (and Glide's own arrangement changes cause some): the idle
    /// display is re-evaluated once they have settled.
    static let reconcileDelay: TimeInterval = 0.5

    private(set) var config = VirtualDisplayConfig()
    private var loaded = false
    private var started = false
    private var lifecycle = VirtualDisplayLifecycle()
    private var display: GLDVirtualDisplay?
    /// The settings applied to `display`.
    private(set) var plan: VirtualDisplayPlan?
    /// The viewer size (or fixed size) `plan` was made for.
    private var plannedFor: (w: Int, h: Int)?
    /// The connected viewer's monitor refresh rate (ClientHello max_fps; 0 = unknown).
    private var viewerHz: Int?
    private(set) var arrangement: Arrangement = .none
    /// The monitor that mirrors the virtual display right now (streaming, "mirror").
    var mirroredPhysical: CGDirectDisplayID? { arrangement.mirroring }
    /// Removed from service but not yet released: every display was asleep (macOS would defer the
    /// removal anyway); released at the next wake, or reused by the next session.
    private var releaseOnWake = false
    /// A monitor whose mirror of the display failed to end while every display slept: its mode is
    /// restored once the displays wake and the display is really gone (`screensWoke`).
    private var restoreOnWake: CGDirectDisplayID?
    /// Retries hiding the idle display after a refused transaction (`standby`).
    private var standbyRetry: DispatchWorkItem?
    private var standbyAttempts = 0
    private var lingerTimer: DispatchWorkItem?
    private var lingerUntil: Date?
    private var reconcileWork: DispatchWorkItem?
    /// Answers owed to connecting viewers (`sessionBegan(ready:)`, and the re-create in
    /// `applyPolicy`): given once the display is online and arranged, or failed. Kept while a
    /// creation is in flight, which answers them itself (`answerReady`).
    private var readyWaiters: [(Bool) -> Void] = []
    /// Bumped on every create/destroy/apply so stale async completions do nothing.
    private var generation = 0
    private(set) var lastError: String?
    private(set) var lastAction: String?
    /// Why the current session streams the physical display instead (for the menu).
    private(set) var skippedReason: String?

    var displayID: CGDirectDisplayID? { display.map(\.displayID).flatMap { $0 == 0 ? nil : $0 } }
    /// The display exists and is Glide's served default (not pending release).
    var exists: Bool { displayID != nil && !releaseOnWake }
    static var unavailableReason: String? { GLDVirtualDisplay.unavailableReason() }

    /// Enabled, and not turned off by a `--display` pin (unless host.json enables it explicitly).
    var active: Bool { config.isEnabled && (config.explicitlyEnabled || ActiveDisplay.pinned == nil) }

    // MARK: Setup

    /// Loads host.json `virtualDisplay` without side effects (also used by --selftest-ui).
    func loadConfig() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: HostConfig.url), let c = try? JSONDecoder().decode(HostConfig.self, from: d) {
            config = c.virtualDisplay ?? VirtualDisplayConfig()
        }
        lifecycle = VirtualDisplayLifecycle(enabled: active, alwaysOn: config.alwaysOn, keepAlive: config.keepAlive)
    }

    func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true
            loadConfig()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screenParametersChanged()
            }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screensWoke()
            }
            let stale = Self.staleDisplays(excluding: nil)
            if !stale.isEmpty {
                log("virtual display: \(stale.map(String.init).joined(separator: ", ")) left by an earlier glide-host is still online (macOS removes it at the next display wake)")
            }
            if config.isEnabled && !active {
                log("virtual display: off by default because --display pins display \(ActiveDisplay.pinned ?? 0) (set virtualDisplay.enabled to true to use both)")
            }
            guard active else { log("virtual display: off; Glide streams the physical display"); return }
            log("virtual display: on (\(config.alwaysOn ? "always on" : "created per session, removed \(Int(config.keepAlive)) s after the viewer leaves")"
                + ", with a monitor: \(config.monitorMode.rawValue)\(config.monitorMode == .extend && config.wantsMain ? " (main)" : "")"
                + ", \(config.refreshRate.map { "\(Int($0)) Hz" } ?? "viewer's refresh rate")\(config.fixedSize.map { ", fixed \($0.w)x\($0.h)" } ?? ""))")
            if let why = Self.unavailableReason { log("virtual display: UNAVAILABLE (\(why)); Glide will use the physical display") }
            let wanted = self.wanted
            if config.alwaysOn && !wanted { log("virtual display: not created at launch: \(Self.streamReason)") }
            perform(lifecycle.launched(wanted: wanted), reason: "always on")
        }
    }

    // MARK: Hooks from DisplayModeController (main queue)

    /// A viewer authenticated. `ready(exists)` runs on main once the display is online and arranged
    /// (or right away if the feature is off or not wanted now, or failed: then Glide serves the
    /// physical display).
    func sessionBegan(viewerHz hz: Int, ready: @escaping (Bool) -> Void) {
        loadConfig()
        viewerHz = hz > 0 ? hz : nil
        skippedReason = nil
        let wanted = self.wanted
        let a = lifecycle.sessionBegan(wanted: wanted)
        if lifecycle.enabled && !wanted {
            // "stream" with a monitor attached: no virtual display at all, even an always-on one.
            skippedReason = Self.streamReason
            log("virtual display: not used for this viewer: \(Self.streamReason)")
            perform(a, reason: "\"stream\" with a monitor attached")
            ready(false)
            return
        }
        if a == .create, let why = reasonToSkip() {
            lifecycle.lost()  // stays off for this session; sessionActive is remembered
            skippedReason = why
            log("virtual display: not used for this viewer: \(why)")
            ready(false)
            return
        }
        perform(a, reason: "viewer connected", ready: ready)
    }

    func sessionEnded() {
        perform(lifecycle.sessionEnded(now: Self.now(), onlyDisplay: isOnlyDisplay, wanted: wanted), reason: "viewer disconnected")
    }

    func owns(_ id: CGDirectDisplayID) -> Bool { id != 0 && displayID == id }

    /// Applies the display-mode policy to the virtual display: re-applies its settings for the
    /// current viewer size, refresh rate and preference (re-creating it only if the viewer outgrew
    /// the limits fixed at creation). True if its mode changes; Glide then posts a
    /// screen-parameters notification once the new mode is read back, so the session re-captures.
    func applyPolicy(reason: String) -> Bool {
        guard exists, let d = display, let cur = plan, let (p, size) = desiredPlan() else { return false }
        plannedFor = size
        if p == cur { return false }
        if p.fits(maxPixelsWide: Int(d.maxPixelsWide), maxPixelsHigh: Int(d.maxPixelsHigh)) {
            do { try apply(p, to: d) } catch {
                note(error: "could not switch to \(p): \(error.localizedDescription)")
                return false
            }
            plan = p
            ActiveDisplay.setVirtual(d.displayID, mode: p.expected)
            note(action: "\(cur) -> \(p) (\(reason))")
            let gen = generation
            settle(d, p, gen: gen) { _ in
                // Re-capture with the mode read back (macOS's own notification may come earlier).
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            }
            return true
        }
        note(action: "re-creating for \(p): larger than the \(d.maxPixelsWide)x\(d.maxPixelsHigh) px limit set at creation (\(reason))")
        // What the new display sets up is decided when it is online (lifecycle.created()), not now.
        release(reason: "re-create", allowDefer: false)
        readyWaiters.append { _ in
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        }
        create(reason: reason)
        return true
    }

    // MARK: Menu (main thread)

    func setEnabled(_ on: Bool) { persist { $0.enabled = on }; reconfigure(reason: on ? "enabled" : "disabled") }
    func setAlwaysOn(_ on: Bool) { persist { $0.lifetime = on ? "always" : "session" }; reconfigure(reason: on ? "always on" : "per session") }
    func setMonitorMode(_ m: VirtualDisplayMonitorMode) {
        persist { $0.whenMonitorAttached = m.rawValue }
        log("virtual display: with a monitor attached: \(m.rawValue) (from the next connection)")
        // An idle display goes now if "stream" no longer wants one; a connected viewer keeps it.
        reconfigure(reason: "with a monitor: \(m.rawValue)")
    }
    func setMakeMain(_ on: Bool) {
        persist { $0.makeMain = on }
        guard exists, lifecycle.phase == .inUse, config.monitorMode == .extend else { return }
        if on { _ = setArrangement(streamingArrangement()) } else { _ = setArrangement(.none) }
    }

    /// Remove the display now (no viewer connected).
    func removeNow() { perform(lifecycle.removeRequested(), reason: "menu") }

    /// Before quitting: put the arrangement back and remove the display. Process exit would remove
    /// it too while the displays are awake, but not the arrangement (macOS dissolves a mirror set
    /// whose master disappears and may leave the monitor in another mode). Returns the monitor
    /// that stopped mirroring and when, for `DisplayModeController.restoreBeforeExit`.
    @discardableResult
    func shutdown(reason: String) -> (display: CGDirectDisplayID, at: TimeInterval)? {
        reconcileWork?.cancel(); reconcileWork = nil
        guard display != nil else { generation += 1; return nil }  // also cancels a pending create
        if Self.allDisplaysAsleep() {
            log("virtual display: every display is asleep; macOS removes display \(displayID ?? 0) at the next display wake")
        }
        return release(reason: reason, allowDefer: false)
    }

    var sessionHoldsIt: Bool { lifecycle.phase == .inUse && exists }

    /// One line for the menu.
    var statusLine: String {
        if !config.isEnabled { return "Off — streaming the Mac's display" }
        if !active { return "Off — --display pins a display" }
        if let why = Self.unavailableReason { return "Unavailable: \(why)" }
        guard exists, let id = displayID, let p = plan else {
            if let s = skippedReason, DisplayModeController.shared.sessionActive { return "Not used: \(s)" }
            return lastError.map { "Not running — \($0)" } ?? (config.alwaysOn ? "Starting…" : "Created when a viewer connects")
        }
        let m = ActiveDisplay.mode(of: id) ?? p.expected
        var s = (m.hiDPI ? "Looks like \(m.width)×\(m.height) (HiDPI, \(m.pixelWidth)×\(m.pixelHeight) px)" : "\(m.width)×\(m.height) (1x)")
            + " @ \(Int(p.refreshRate.rounded())) Hz"
        switch arrangement {
        case .mirror: s += ", monitor mirrors it"
        case .extendMain: s += ", main display"
        case .hidden: s += ", idle"
        case .none: break
        }
        if let until = lingerUntil { s += " — idle in \(max(0, Int(until.timeIntervalSinceNow.rounded()))) s" }
        return s
    }

    // MARK: Core

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func perform(_ a: VirtualDisplayLifecycle.Action, reason: String, ready: ((Bool) -> Void)? = nil) {
        // The lifecycle has already moved: a pending linger timer only matters while lingering.
        if case .lingering = lifecycle.phase {} else { lingerTimer?.cancel(); lingerTimer = nil; lingerUntil = nil }
        if let ready { readyWaiters.append(ready) }
        switch a {
        case .none:
            answerReady()
        case .create:
            create(reason: reason)
        case .resume:
            resume(reason: reason)
        case .awaitCreation:
            // Connected while the display is still being created (always-on at launch, a launchd
            // relaunch with the viewer reconnecting): the creation arranges it for streaming,
            // because the phase is .inUse when it finishes, and answers this viewer.
            log("virtual display: \(reason) while it is being created; streaming it once it is online")
        case .standby:
            standby(reason: reason)
            answerReady()
        case .destroy:
            release(reason: reason, allowDefer: true)
            answerReady()
        case let .scheduleTimer(at):
            lingerTimer?.cancel()
            let delay = max(0, at - Self.now())
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lingerTimer = nil
                self.lingerUntil = nil
                self.perform(self.lifecycle.timerFired(now: Self.now(), onlyDisplay: self.isOnlyDisplay, wanted: self.wanted),
                             reason: "no viewer for \(Int(self.config.keepAlive)) s")
            }
            lingerTimer = work
            lingerUntil = Date().addingTimeInterval(delay)
            log("virtual display: keeping the arrangement for \(Int(delay)) s in case the viewer reconnects")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            answerReady()
        }
    }

    /// Gives every owed answer (`readyWaiters`) the current state, unless a creation or a resume is
    /// in flight: it answers once the display is online, arranged and its mode read back, or failed.
    private func answerReady() {
        guard lifecycle.mayAnswer, !readyWaiters.isEmpty else { return }
        let w = readyWaiters
        readyWaiters = []
        let e = exists
        w.forEach { $0(e) }
    }

    private func reconfigure(reason: String) {
        loadConfig()
        perform(lifecycle.configure(enabled: active, alwaysOn: config.alwaysOn, keepAlive: config.keepAlive, onlyDisplay: isOnlyDisplay, wanted: wanted),
                reason: reason)
    }

    static let streamReason = "a monitor is attached and whenMonitorAttached is \"stream\""

    /// A virtual display is wanted with the displays online now: not with "stream" and a monitor.
    private var wanted: Bool {
        VirtualDisplayTopology.wantsVirtual(mode: config.monitorMode, physicalDisplays: Self.physicalDisplays(excluding: displayID).count)
    }

    /// Why a connecting viewer should get the physical display instead (nil: use the virtual one).
    /// ("stream" with a monitor is decided by the lifecycle, `wanted`.)
    private func reasonToSkip() -> String? {
        let physical = Self.physicalDisplays(excluding: displayID)
        // The main monitor already shows exactly what the viewer wants: stream it 1:1, change nothing.
        let main = CGMainDisplayID()
        if physical.contains(main), let (p, _) = desiredPlan(), p.matches(CGDisplayCopyDisplayMode(main).map(DisplayModeInfo.init)) {
            return "the main monitor is already \(p.expected), exactly the viewer's size"
        }
        return nil
    }

    /// The plan for the current viewer (or the fixed / last / default size), refresh rate and preference.
    private func desiredPlan() -> (VirtualDisplayPlan, (w: Int, h: Int))? {
        let dm = DisplayModeController.shared
        let size = config.fixedSize ?? dm.viewerSize ?? plannedFor ?? VirtualDisplayConfig.defaultSize
        let hz = config.refreshRate(viewerHz: viewerHz)
        // "Don't Change": keep whatever the display has (a new display still needs a first mode).
        if dm.effectivePreference == .manual, let p = plan { return (p, plannedFor ?? size) }
        guard let p = VirtualDisplayPlan.make(viewerW: size.w, viewerH: size.h, preference: dm.effectivePreference,
                                              highDPIChoice: dm.settings.highDPIChoice, refreshRate: hz) else { return nil }
        return (p, size)
    }

    /// Creates the display; once it is online and its mode read back, sets up what the lifecycle
    /// says *then* (`created()`): a viewer may have connected or left meanwhile.
    private func create(reason: String) {
        func fail(_ msg: String) {
            note(error: msg)
            log("virtual display: falling back to the physical display")
            lifecycle.lost()
            answerReady()
        }
        if let why = Self.unavailableReason { fail("unavailable: \(why)"); return }
        guard let (wanted, size) = desiredPlan() else { fail("no usable size for the viewer"); return }
        // A display we took out of service while the screens slept: reuse it.
        if let d = display, releaseOnWake {
            releaseOnWake = false
            log("virtual display: reusing display \(d.displayID) (its removal was waiting for the displays to wake)")
            ActiveDisplay.setVirtual(d.displayID, mode: plan?.expected)
            restoreOnWake = nil  // it is used again; a mirror that never ended is taken over below
            switch lifecycle.created() {
            case .streaming: lifecycle.resumeStarted(); resume(reason: reason)
            case .standby: standby(reason: "no viewer"); answerReady()
            case .keep: answerReady()
            case .discard: release(reason: "no longer wanted", allowDefer: true); answerReady()
            }
            recheckDisplaysAfterCreate()
            return
        }
        lifecycle.recreating()  // (already set when the lifecycle asked for it)
        if display != nil { release(reason: "replaced", allowDefer: false) }
        // The physical display goes back to its own mode before the virtual one takes over.
        DisplayModeController.shared.restorePhysicalBeforeVirtual()
        let limits = VirtualDisplayPlan.creationLimits(viewerW: size.w, viewerH: size.h, highDPIChoice: DisplayModeController.shared.settings.highDPIChoice)
        let mm = wanted.sizeInMillimeters
        generation += 1
        let gen = generation
        let stale = Self.staleDisplays(excluding: nil)
        if !stale.isEmpty {
            // Left by an earlier process while the displays slept; the session's wake removes it.
            log("virtual display: waiting for leftover display \(stale.map(String.init).joined(separator: ", ")) to go away")
            Power.wakeDisplay()
        }
        let deadline = Date().addingTimeInterval(stale.isEmpty ? 0 : 3)
        // Superseded (removed or re-created meanwhile): whoever superseded it answers the viewers.
        func attempt() {
            guard gen == generation else { answerReady(); return }
            if !Self.staleDisplays(excluding: nil).isEmpty && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { attempt() }
                return
            }
            var d: GLDVirtualDisplay?
            var lastErr: Error?
            for serial in Self.serialNumbers {
                do {
                    d = try GLDVirtualDisplay(name: Self.displayName, vendorID: Self.vendorID, productID: Self.productID, serialNumber: serial,
                                              maxPixelsWide: UInt32(limits.w), maxPixelsHigh: UInt32(limits.h),
                                              sizeInMillimeters: CGSize(width: mm.w, height: mm.h), queue: .main,
                                              onTerminate: { [weak self] in self?.terminated(gen) })
                    if serial != Self.serialNumbers[0] { log("virtual display: serial \(Self.serialNumbers[0]) is taken by a leftover display; using serial \(serial)") }
                    break
                } catch { lastErr = error }
            }
            guard let d else { fail("could not create it: \(lastErr?.localizedDescription ?? "unknown error")"); return }
            var p = wanted
            do {
                do { try apply(p, to: d) } catch where p.refreshRate > 60 {
                    log("virtual display: \(Int(p.refreshRate)) Hz refused (\(error.localizedDescription)); trying 60 Hz")
                    p.refreshRate = 60
                    try apply(p, to: d)
                }
            } catch {
                d.invalidate()
                fail("could not configure it: \(error.localizedDescription)"); return
            }
            display = d
            plan = p
            plannedFor = size
            lastError = nil
            arrangement = .none
            ActiveDisplay.setVirtual(d.displayID, mode: p.expected)
            note(action: "created display \(d.displayID): \(p), limit \(limits.w)x\(limits.h) px (\(reason))")
            let id = d.displayID
            let online = Date().addingTimeInterval(Self.onlineTimeout)
            func poll() {
                guard gen == generation, display != nil else { answerReady(); return }
                if ActiveDisplay.isOnline(id) {
                    settle(d, p, gen: gen) { [self] _ in
                        guard gen == generation, display != nil else { answerReady(); return }
                        // Decided now, not when the creation started: a viewer that connected
                        // meanwhile gets the streaming arrangement, and an idle display is hidden.
                        let ready = lifecycle.created()
                        // Displays that changed meanwhile are handled now, with the displays online now.
                        defer { recheckDisplaysAfterCreate() }
                        switch ready {
                        case .streaming: _ = setArrangement(streamingArrangement())
                        case .standby: standby(reason: "no viewer")
                        case .keep: break
                        case .discard: release(reason: "no longer wanted", allowDefer: true); answerReady(); return
                        }
                        // A moment for WindowServer to publish the new arrangement before capture starts.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in answerReady() }
                    }
                } else if Date() > online {
                    release(reason: "not online", allowDefer: false)
                    fail("display \(id) did not come online within \(Int(Self.onlineTimeout)) s")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
                }
            }
            poll()
        }
        attempt()
    }

    /// A viewer connects to the display that already exists (lingering or standby): arrange it for
    /// streaming, size it for this viewer, read the mode back. Holds one `lifecycle.resuming` count
    /// (taken by `sessionBegan`, or by the caller) until then, so no other path answers the viewer
    /// with the display half set up.
    private func resume(reason: String) {
        guard let d = display, !releaseOnWake else { lifecycle.resumeFinished(); create(reason: reason); return }
        // Out of a hidden mirror first: a mirror slave's mode follows its master, not our settings.
        _ = setArrangement(streamingArrangement())
        let gen = generation
        if let (p, size) = desiredPlan(), p != plan, p.fits(maxPixelsWide: Int(d.maxPixelsWide), maxPixelsHigh: Int(d.maxPixelsHigh)) {
            do { try apply(p, to: d); plan = p; plannedFor = size; note(action: "resized for the viewer: \(p) (\(reason))") } catch {
                note(error: "could not resize for the viewer: \(error.localizedDescription)")
            }
        } else if let (p, _) = desiredPlan(), !p.fits(maxPixelsWide: Int(d.maxPixelsWide), maxPixelsHigh: Int(d.maxPixelsHigh)) {
            lifecycle.resumeFinished()
            release(reason: "viewer outgrew it", allowDefer: false)
            create(reason: reason)
            return
        }
        guard let p = plan else { lifecycle.resumeFinished(); answerReady(); return }
        // Capture and input mapping use the planned mode until settle reads the real one back.
        ActiveDisplay.setVirtual(d.displayID, mode: p.expected)
        settle(d, p, gen: gen) { [self] _ in
            guard gen == generation else { lifecycle.resumeFinished(); answerReady(); return }
            // Re-capture with the mode read back (macOS's own notification may come earlier, or
            // not at all when only the arrangement changed).
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in lifecycle.resumeFinished(); answerReady() }
        }
    }

    /// No viewer, display kept: give the Mac its arrangement back and hide the display behind the
    /// main monitor (mirroring it), so the idle display adds no invisible desktop area. Re-run on
    /// display changes, so it follows a new main monitor.
    private func standby(reason: String) {
        standbyRetry?.cancel(); standbyRetry = nil
        guard exists else { return }
        let target = standbyTarget()
        if setArrangement(target) {
            standbyAttempts = 0
            if target != .none { note(action: "idle, hidden behind display \(target.physical ?? 0) (\(reason))") }
            return
        }
        // Refused (typically .mirror(P) -> .hidden(P)): never leave the monitor mirroring an idle
        // display. Back to .none (the mirror ends, P gets its mode back: mirrorEnded), then try
        // hiding again later. If even that is refused the mirror is real, so `.mirror(P)` is kept:
        // P's restore waits for it (heldByMirror) and the retry tries again.
        let leaving = arrangement.mirroring
        if !setArrangement(.none), let p = leaving {
            log("virtual display: could not end the mirror of display \(p) either; it keeps mirroring the idle display until the retry")
        }
        standbyAttempts += 1
        guard let delay = VirtualDisplayLifecycle.standbyRetryDelay(attempt: standbyAttempts) else {
            log("virtual display: could not hide the idle display after \(standbyAttempts) attempts; the next display change tries again")
            standbyAttempts = 0
            return
        }
        log("virtual display: could not hide the idle display (\(reason)); left extended, retrying in \(Int(delay)) s")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.standbyRetry = nil
            guard self.lifecycle.phase == .standby, !self.lifecycle.creating, self.exists else { self.standbyAttempts = 0; return }
            self.standby(reason: "retry")
        }
        standbyRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Back to `.none` before the display is removed, even if the transaction fails. Never keeps a
    /// stale arrangement: `.mirror(P)`
    /// would block every later restore of P (heldByMirror), and the next mirror would save the
    /// wrong mode. A monitor whose mirror could not be ended gets its mode restored once the
    /// display is removed (which ends the mirror): after its settle time, or at the next wake if
    /// every display sleeps (macOS defers the removal until then).
    private func clearArrangement() {
        let leaving = arrangement.mirroring
        guard !setArrangement(.none) || arrangement != .none else { return }
        if let p = leaving {
            if Self.allDisplaysAsleep() {
                restoreOnWake = p
                log("virtual display: could not end the mirror of display \(p) while the displays sleep; its mode is restored after they wake")
            } else {
                log("virtual display: could not end the mirror of display \(p); removing the display ends it")
                mirrorEnded(p)
            }
        }
        arrangement = .none
    }

    /// Hidden behind the main monitor: the main display if it is physical, else the monitor it is
    /// hidden behind now (still online), else any monitor; alone without one. A monitor that
    /// mirrors another monitor (the user's own mirror set) is never the target.
    private func standbyTarget() -> Arrangement {
        let physical = Self.physicalDisplays(excluding: displayID)
        let masters = physical.filter { let m = CGDisplayMirrorsDisplay($0); return m == kCGNullDirectDisplay || m == displayID }
        let main = CGMainDisplayID()
        let current = arrangement.physical.flatMap { masters.contains($0) ? $0 : nil }
        guard let m = masters.first(where: { $0 == main }) ?? current ?? masters.first ?? physical.first else { return .none }
        return .hidden(behind: m)
    }

    /// Restores the arrangement and releases the display. With `allowDefer`, a display whose
    /// screens are all asleep is only taken out of service and released at the next wake (macOS
    /// would defer the removal anyway, and a same-identity display can't be created meanwhile).
    /// Always leaves the arrangement `.none`; a monitor that mirrored it gets its mode restored
    /// even if ending the mirror failed (removing the display ends it). Returns that monitor.
    @discardableResult
    private func release(reason: String, allowDefer: Bool) -> (display: CGDirectDisplayID, at: TimeInterval)? {
        lingerTimer?.cancel(); lingerTimer = nil; lingerUntil = nil
        generation += 1  // also cancels a create still waiting for a leftover display to go away
        guard let d = display else { return nil }
        let id = d.displayID
        let leaving = arrangement.mirroring
        standbyRetry?.cancel(); standbyRetry = nil; standbyAttempts = 0
        clearArrangement()
        ActiveDisplay.setVirtual(nil, mode: nil)
        if allowDefer && Self.allDisplaysAsleep() {
            releaseOnWake = true
            note(action: "display \(id) out of service; removed when the displays wake (\(reason))")
            return leaving.map { ($0, Self.now()) }
        }
        releaseOnWake = false
        d.invalidate()
        display = nil
        plan = nil
        note(action: "removed display \(id) (\(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.displayID != id, Self.onlineDisplays().contains(id) else { return }
            log("virtual display: display \(id) is still online 4 s after release\(Self.allDisplaysAsleep() ? " (displays asleep: macOS removes it at the next wake)" : "")")
        }
        return leaving.map { ($0, Self.now()) }
    }

    /// `p` stopped mirroring the display: DisplayModeController treats the mode change macOS makes
    /// next as settling (not the user's) and gives `p` its own mode back once macOS has settled it.
    private func mirrorEnded(_ p: CGDirectDisplayID) {
        let now = Self.now()
        lastUnmirror = (p, now)
        DisplayModeController.shared.mirrorEnded(p, at: now)
        DispatchQueue.main.asyncAfter(deadline: .now() + ModeRestore.afterMirrorSettle) { DisplayModeController.shared.restoreAfterMirror(p) }
    }

    /// The last monitor that stopped mirroring the display, and when (uptime): the exit restore
    /// waits for it to settle (`restoreDisplaysBeforeExit`).
    private(set) var lastUnmirror: (display: CGDirectDisplayID, at: TimeInterval)?

    private func screensWoke() {
        if releaseOnWake, let d = display {
            releaseOnWake = false
            let id = d.displayID
            d.invalidate()
            display = nil
            plan = nil
            note(action: "removed display \(id) (displays woke)")
        }
        // The removal ended a mirror that couldn't be ended while the displays slept.
        if let p = restoreOnWake {
            restoreOnWake = nil
            log("virtual display: displays woke; display \(p) no longer mirrors it")
            mirrorEnded(p)
        }
    }

    /// The system ended the display (WindowServer restart, ...).
    private func terminated(_ gen: Int) {
        guard gen == generation, let d = display else { return }
        note(error: "macOS removed display \(d.displayID)")
        // The mirror ended with it: the monitor gets its own mode back.
        if let p = arrangement.mirroring { mirrorEnded(p) }
        standbyRetry?.cancel(); standbyRetry = nil
        arrangement = .none
        generation += 1
        ActiveDisplay.setVirtual(nil, mode: nil)
        d.invalidate()
        display = nil
        plan = nil
        releaseOnWake = false
        lifecycle.lost()
        answerReady()
    }

    private func apply(_ p: VirtualDisplayPlan, to d: GLDVirtualDisplay) throws {
        try d.applyMode(width: UInt32(p.modeWidth), height: UInt32(p.modeHeight), refreshRate: p.refreshRate, hiDPI: p.hiDPI)
    }

    // MARK: Reading the mode back

    /// Waits until macOS shows the planned size, then records the mode it actually uses (capture,
    /// input mapping and DisplayInfo use it). `done` is always called, once: with the mode read
    /// back, or, if the display was removed, re-created or given a newer plan meanwhile, with the
    /// mode known now (the newer action reads its own mode back; an old plan is never re-applied).
    ///
    /// The creating process gets no CoreGraphics mode for its own virtual display and AppKit does
    /// not list it, so: CGDisplayBounds (points; reliable in-process) must reach the planned
    /// looks-like size, re-applying the settings once if it doesn't (macOS 27 sometimes ignores the
    /// first settings of a new display), and a child process reads the pixel size
    /// (`glide-host --list-display-modes ID`). Without the child, matching points mean the plan.
    private func settle(_ d: GLDVirtualDisplay, _ p: VirtualDisplayPlan, gen: Int, retried: Bool = false, done: @escaping (DisplayModeInfo) -> Void) {
        let id = d.displayID
        let deadline = Date().addingTimeInterval(2)
        func superseded() -> Bool { gen != generation || display !== d || plan != p }
        func known() -> DisplayModeInfo { ActiveDisplay.mode(of: id) ?? p.expected }
        func pointsMatch() -> Bool {
            let b = CGDisplayBounds(id)
            return Int(b.width.rounded()) == p.expected.width && Int(b.height.rounded()) == p.expected.height
        }
        func poll() {
            if superseded() { done(known()); return }
            if case .hidden = arrangement { done(p.expected); return }  // a mirror slave shows its master's size
            if pointsMatch() { probe(); return }
            if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }; return }
            if !retried {
                log("virtual display: macOS shows \(Self.boundsText(id)), not \(p.expected.width)x\(p.expected.height) pt; re-applying the settings")
                do { try apply(p, to: d) } catch { log("virtual display: re-apply failed: \(error.localizedDescription)") }
                settle(d, p, gen: gen, retried: true, done: done)
                return
            }
            probe()
        }
        func probe() {
            DispatchQueue.global(qos: .userInitiated).async {
                let child = DisplayModeProbe.current(of: id)
                DispatchQueue.main.async {
                    if superseded() { done(known()); return }
                    let b = CGDisplayBounds(id)
                    let actual = Self.conclude(boundsW: Int(b.width.rounded()), boundsH: Int(b.height.rounded()), child: child, plan: p)
                    if !actual.sameSize(p.expected) {
                        log("virtual display: macOS shows \(actual), not the planned \(p.expected); capturing what it shows")
                    } else {
                        log("virtual display: display \(id) is \(actual) @ \(Int(actual.refreshRate.rounded())) Hz\(child == nil ? " (pixel size from the plan: mode probe unavailable)" : "")")
                    }
                    ActiveDisplay.setVirtual(id, mode: actual)
                    done(actual)
                }
            }
        }
        poll()
    }

    private static func boundsText(_ id: CGDirectDisplayID) -> String {
        let b = CGDisplayBounds(id)
        return "\(Int(b.width))x\(Int(b.height)) pt"
    }

    // MARK: Display changes

    private func screenParametersChanged() {
        // The mode only changes when Glide re-applies settings (settle reads it). What does change:
        // monitors come and go, the lid opens or closes. Re-evaluated once the burst settles.
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcileWork = nil
            self?.displaysChanged()
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconcileDelay, execute: work)
    }

    /// Brings the arrangement in line with the displays online now (VirtualDisplayLayout.reconcile)
    /// and re-evaluates an idle display (VirtualDisplayLifecycle.displaysChanged): removed when it
    /// is no longer the only display and isn't always-on (or "stream" no longer wants it), hidden
    /// behind the new main monitor when always-on.
    private func displaysChanged() {
        guard started, active else { return }
        if lifecycle.creating {
            // Recorded, and handled once the create finishes (recheckDisplaysAfterCreate).
            _ = lifecycle.displaysChanged(onlyDisplay: isOnlyDisplay, wanted: wanted)
            return
        }
        if let v = displayID, !releaseOnWake {
            let others = Self.onlineDisplays().filter { $0 != v && !Self.isGlideDisplay($0) }.map {
                VirtualDisplayTopology.Display(id: $0, mirrorOf: CGDisplayMirrorsDisplay($0))
            }
            for fix in VirtualDisplayLayout.reconcile(arrangement, virtual: v, streaming: lifecycle.phase == .inUse, mode: config.monitorMode, displays: others) {
                switch fix {
                case let .forget(p):
                    let was = arrangement
                    arrangement = .none
                    switch was {
                    case .mirror:
                        // No transaction on an offline display; its mode is restored when it is back.
                        note(action: "display \(p) went offline while it mirrored the virtual display")
                        DisplayModeController.shared.restoreAfterMirror(p)
                    case .hidden:
                        note(action: "display \(p), which the idle display was hidden behind, went offline")
                        if CGDisplayMirrorsDisplay(v) != kCGNullDirectDisplay { _ = Self.configure { CGConfigureDisplayMirrorOfDisplay($0, v, kCGNullDirectDisplay) } }
                    case .extendMain, .none:
                        note(action: "display \(p) went offline")
                    }
                case let .unmirror(p):
                    // Typically the built-in panel coming back (lid opened) still in the mirror set.
                    let ok = Self.configure { CGConfigureDisplayMirrorOfDisplay($0, p, kCGNullDirectDisplay) }
                    note(action: "display \(p) came back mirroring the virtual display: \(ok ? "mirror ended" : "could not end the mirror")")
                    mirrorEnded(p)
                case let .adopt(p):
                    arrangement = .mirror(physical: p)
                    note(action: "display \(p) came back and mirrors the virtual display again")
                }
            }
        }
        perform(lifecycle.displaysChanged(onlyDisplay: isOnlyDisplay, wanted: wanted), reason: "displays changed")
    }

    /// Displays changed while the create that just finished was in flight: handle them now.
    private func recheckDisplaysAfterCreate() {
        guard lifecycle.takeDisplaysChangedDuringCreate() else { return }
        log("virtual display: displays changed while it was being created; re-evaluating")
        screenParametersChanged()
    }

    // MARK: Arrangement

    private var isOnlyDisplay: Bool { Self.physicalDisplays(excluding: displayID).isEmpty }

    /// The main physical display (the one that has the menu bar when the virtual display isn't main).
    private func mainPhysical() -> CGDirectDisplayID? {
        if case let .mirror(p) = arrangement { return p }
        if case let .extendMain(prev) = arrangement { return prev }
        if case let .hidden(p) = arrangement, Self.onlineDisplays().contains(p) { return p }
        let main = CGMainDisplayID()
        return main == displayID ? nil : main
    }

    /// The arrangement for streaming (VirtualDisplayTopology, unit-tested).
    private func streamingArrangement() -> Arrangement {
        guard let v = displayID else { return .none }
        let displays = Self.onlineDisplays().filter { !Self.isGlideDisplay($0) || $0 == v }.map {
            VirtualDisplayTopology.Display(id: $0, mirrorOf: CGDisplayMirrorsDisplay($0))
        }
        // While hidden, the virtual display mirrors the monitor; plan as if it didn't.
        let main = mainPhysical() ?? CGMainDisplayID()
        let unhidden = displays.map { $0.id == v ? VirtualDisplayTopology.Display(id: v) : $0 }
        switch VirtualDisplayTopology.choose(mode: config.monitorMode, makeMain: config.wantsMain, virtual: v, main: main, displays: unhidden) {
        case .alone: return .none
        case let .mirror(p): return .mirror(physical: p)
        case let .extend(makeMain): return makeMain ? .extendMain(previousMain: main) : .none
        }
    }

    /// Moves from the current arrangement to `target`. Mirror changes are one display-configuration
    /// transaction; leaving or entering "main" is a separate translation. Always `.forSession`.
    @discardableResult
    private func setArrangement(_ target: Arrangement) -> Bool {
        guard let v = displayID else { arrangement = .none; return false }
        let from = arrangement
        if from == target { return true }
        func mirrorKind(_ a: Arrangement) -> Bool { if case .extendMain = a { return false }; return true }
        if !mirrorKind(from) || !mirrorKind(target) {
            // Via .none: undo "main", then apply the target.
            if case let .extendMain(prev) = from {
                if CGMainDisplayID() == v, ActiveDisplay.isOnline(prev), Self.arrange(main: prev) { log("virtual display: display \(prev) is the main display again") }
                arrangement = .none
            } else if from != .none {
                _ = setArrangement(.none)
            }
            if case let .extendMain(prev) = target {
                guard CGMainDisplayID() != v else { arrangement = target; return true }
                if Self.arrange(main: v) {
                    arrangement = .extendMain(previousMain: prev)
                    note(action: "made display \(v) the main display (was \(prev))")
                    return true
                }
                note(error: "could not make it the main display")
                return false
            }
            return true
        }
        // Remember the monitor's own mode before it mirrors us: macOS switches a mirror slave to a
        // matching mode (and normally restores it when the mirror ends; if it doesn't, Glide does).
        if case let .mirror(p) = target { DisplayModeController.shared.rememberBeforeMirror(p) }
        let online = Self.onlineDisplays()
        let ok = Self.configure { cfg in
            switch from {
            case let .mirror(p):
                // A monitor that went offline (lid closed) is left out: configuring an offline
                // display fails the whole transaction.
                if online.contains(p) {
                    CGConfigureDisplayMirrorOfDisplay(cfg, p, kCGNullDirectDisplay)
                    CGConfigureDisplayOrigin(cfg, p, 0, 0)
                }
                if target == .none {  // keep the (soon removed) virtual display out of the way, to the right
                    let w = DisplayModeController.shared.rememberedMode(of: p)?.width ?? Int(CGDisplayBounds(p).width)
                    CGConfigureDisplayOrigin(cfg, v, Int32(clamping: w), 0)
                }
            case .hidden:
                CGConfigureDisplayMirrorOfDisplay(cfg, v, kCGNullDirectDisplay)
            case .none, .extendMain:
                break
            }
            switch target {
            case let .mirror(p):
                CGConfigureDisplayMirrorOfDisplay(cfg, p, v)
                CGConfigureDisplayOrigin(cfg, v, 0, 0)
            case let .hidden(p):
                CGConfigureDisplayMirrorOfDisplay(cfg, v, p)
            case .none, .extendMain:
                break
            }
        }
        guard ok else {
            note(error: "could not change the arrangement (\(Self.describe(from)) -> \(Self.describe(target)))")
            if case let .mirror(p) = target { DisplayModeController.shared.restoreAfterMirror(p) }
            return false
        }
        arrangement = target
        if case let .mirror(p) = target { note(action: "display \(p) mirrors the virtual display \(v) (one desktop, at 0,0)") }
        if case let .mirror(p) = from {
            log("virtual display: display \(p) no longer mirrors it")
            // macOS normally gives the monitor its mode back; check after it settles.
            mirrorEnded(p)
        }
        return true
    }

    private static func describe(_ a: Arrangement) -> String {
        switch a {
        case .none: return "extended"
        case let .mirror(p): return "mirrored by \(p)"
        case .extendMain: return "main"
        case let .hidden(p): return "hidden behind \(p)"
        }
    }

    private static func configure(_ f: (CGDisplayConfigRef?) -> Void) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        f(cfg)
        // forSession: never outlives the login session.
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    /// Makes `id` the main display by translating the whole arrangement (relative positions kept).
    private static func arrange(main id: CGDirectDisplayID) -> Bool {
        var origins: [UInt32: (x: Double, y: Double)] = [:]
        for d in onlineDisplays() where CGDisplayMirrorsDisplay(d) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(d)
            origins[d] = (Double(b.origin.x), Double(b.origin.y))
        }
        guard let new = VirtualDisplayArrangement.makingMain(id, origins: origins) else { return false }
        return configure { cfg in
            for (d, o) in new { CGConfigureDisplayOrigin(cfg, d, Int32(o.x.rounded()), Int32(o.y.rounded())) }
        }
    }

    // MARK: Display queries

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// A display with Glide's virtual-display identity (ours, or one left by an earlier process).
    static func isGlideDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID && CGDisplayModelNumber(id) == productID
    }

    /// Glide virtual displays that aren't `ours`: left by an earlier process while the displays
    /// slept (their removal waits for the next wake).
    static func staleDisplays(excluding ours: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        let mine = ours ?? shared.displayID
        return onlineDisplays().filter { $0 != mine && isGlideDisplay($0) }
    }

    /// Displays that aren't Glide's (monitors, the built-in panel, other apps' virtual displays).
    static func physicalDisplays(excluding ours: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        onlineDisplays().filter { $0 != ours && !isGlideDisplay($0) }
    }

    /// True while every online display sleeps (WindowServer then defers display removal).
    static func allDisplaysAsleep() -> Bool {
        let ids = onlineDisplays()
        return !ids.isEmpty && ids.allSatisfy { CGDisplayIsAsleep($0) == 1 }
    }

    // MARK: Helpers

    private func note(action: String) { lastAction = action; log("virtual display: " + action) }
    private func note(error: String) { lastError = error; log("virtual display: " + error) }

    private func persist(_ f: (inout VirtualDisplayConfig) -> Void) {
        loadConfig()
        f(&config)
        let c = config
        HostConfig.modify { $0.virtualDisplay = c }
    }
}

/// Reads a display's current mode from a child process (`glide-host --list-display-modes ID`):
/// CoreGraphics reports no mode for a virtual display to the process that created it, but other
/// processes see it normally. Blocking; call off the main thread.
enum DisplayModeProbe {
    static func current(of id: CGDirectDisplayID, timeout: TimeInterval = 3) -> DisplayModeInfo? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--list-display-modes", "\(id)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        return DisplayModeInfo.parseListing(String(decoding: data, as: UTF8.self))
    }
}
