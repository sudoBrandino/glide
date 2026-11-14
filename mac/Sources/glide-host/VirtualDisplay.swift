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

    /// How the virtual display sits among the Mac's displays.
    enum Arrangement: Equatable {
        /// Untouched (alone, or extended where macOS put it).
        case none
        /// `physical` mirrors the virtual display, which is at (0,0) (streaming, "mirror").
        case mirror(physical: CGDirectDisplayID)
        /// The virtual display was made main (streaming, "extend"); `previousMain` gets it back.
        case extendMain(previousMain: CGDirectDisplayID)
        /// The virtual display mirrors `physical`: hidden while idle (no extra desktop area).
        case hidden(behind: CGDirectDisplayID)
    }

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
    var mirroredPhysical: CGDirectDisplayID? { if case let .mirror(p) = arrangement { return p }; return nil }
    /// Removed from service but not yet released: every display was asleep (macOS would defer the
    /// removal anyway); released at the next wake, or reused by the next session.
    private var releaseOnWake = false
    private var lingerTimer: DispatchWorkItem?
    private var lingerUntil: Date?
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
            perform(lifecycle.launched(), reason: "always on")
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
        let a = lifecycle.sessionBegan()
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
        perform(lifecycle.sessionEnded(now: Self.now(), onlyDisplay: isOnlyDisplay), reason: "viewer disconnected")
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
        let streaming = lifecycle.phase == .inUse
        release(reason: "re-create", allowDefer: false)
        create(reason: reason, streaming: streaming) { _ in
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        }
        return true
    }

    // MARK: Menu (main thread)

    func setEnabled(_ on: Bool) { persist { $0.enabled = on }; reconfigure(reason: on ? "enabled" : "disabled") }
    func setAlwaysOn(_ on: Bool) { persist { $0.lifetime = on ? "always" : "session" }; reconfigure(reason: on ? "always on" : "per session") }
    func setMonitorMode(_ m: VirtualDisplayMonitorMode) {
        persist { $0.whenMonitorAttached = m.rawValue }
        log("virtual display: with a monitor attached: \(m.rawValue) (from the next connection)")
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
    /// whose master disappears and may leave the monitor in another mode).
    func shutdown(reason: String) {
        guard display != nil else { return }
        if Self.allDisplaysAsleep() {
            log("virtual display: every display is asleep; macOS removes display \(displayID ?? 0) at the next display wake")
        }
        release(reason: reason, allowDefer: false)
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
        switch a {
        case .none:
            ready?(exists)
        case .create:
            create(reason: reason, streaming: lifecycle.phase == .inUse, ready: ready)
        case .resume:
            resume(reason: reason, ready: ready)
        case .standby:
            standby(reason: reason)
            ready?(exists)
        case .destroy:
            release(reason: reason, allowDefer: true)
            ready?(false)
        case let .scheduleTimer(at):
            lingerTimer?.cancel()
            let delay = max(0, at - Self.now())
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lingerTimer = nil
                self.lingerUntil = nil
                self.perform(self.lifecycle.timerFired(now: Self.now(), onlyDisplay: self.isOnlyDisplay), reason: "no viewer for \(Int(self.config.keepAlive)) s")
            }
            lingerTimer = work
            lingerUntil = Date().addingTimeInterval(delay)
            log("virtual display: keeping the arrangement for \(Int(delay)) s in case the viewer reconnects")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            ready?(exists)
        }
    }

    private func reconfigure(reason: String) {
        loadConfig()
        perform(lifecycle.configure(enabled: active, alwaysOn: config.alwaysOn, keepAlive: config.keepAlive, onlyDisplay: isOnlyDisplay), reason: reason)
    }

    /// Why a connecting viewer should get the physical display instead (nil: use the virtual one).
    private func reasonToSkip() -> String? {
        let physical = Self.physicalDisplays(excluding: displayID)
        if !VirtualDisplayTopology.wantsVirtual(mode: config.monitorMode, physicalDisplays: physical.count) {
            return "a monitor is attached and whenMonitorAttached is \"stream\""
        }
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

    private func create(reason: String, streaming: Bool, ready: ((Bool) -> Void)?) {
        func fail(_ msg: String) {
            note(error: msg)
            log("virtual display: falling back to the physical display")
            lifecycle.lost()
            ready?(false)
        }
        if let why = Self.unavailableReason { fail("unavailable: \(why)"); return }
        guard let (wanted, size) = desiredPlan() else { fail("no usable size for the viewer"); return }
        // A display we took out of service while the screens slept: reuse it.
        if let d = display, releaseOnWake {
            releaseOnWake = false
            log("virtual display: reusing display \(d.displayID) (its removal was waiting for the displays to wake)")
            ActiveDisplay.setVirtual(d.displayID, mode: plan?.expected)
            resume(reason: reason, ready: ready)
            return
        }
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
        func attempt() {
            guard gen == generation else { ready?(exists); return }
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
                guard gen == generation, display != nil else { ready?(exists); return }
                if ActiveDisplay.isOnline(id) {
                    settle(d, p, gen: gen) { [self] _ in
                        guard gen == generation, display != nil else { ready?(exists); return }
                        if streaming { _ = setArrangement(streamingArrangement()) } else { standby(reason: "no viewer") }
                        // A moment for WindowServer to publish the new arrangement before capture starts.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in ready?(exists) }
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
    /// streaming, size it for this viewer, read the mode back.
    private func resume(reason: String, ready: ((Bool) -> Void)?) {
        guard let d = display, !releaseOnWake else { create(reason: reason, streaming: true, ready: ready); return }
        // Out of a hidden mirror first: a mirror slave's mode follows its master, not our settings.
        _ = setArrangement(streamingArrangement())
        let gen = generation
        if let (p, size) = desiredPlan(), p != plan, p.fits(maxPixelsWide: Int(d.maxPixelsWide), maxPixelsHigh: Int(d.maxPixelsHigh)) {
            do { try apply(p, to: d); plan = p; plannedFor = size; note(action: "resized for the viewer: \(p) (\(reason))") } catch {
                note(error: "could not resize for the viewer: \(error.localizedDescription)")
            }
        } else if let (p, _) = desiredPlan(), !p.fits(maxPixelsWide: Int(d.maxPixelsWide), maxPixelsHigh: Int(d.maxPixelsHigh)) {
            release(reason: "viewer outgrew it", allowDefer: false)
            create(reason: reason, streaming: true, ready: ready)
            return
        }
        guard let p = plan else { ready?(exists); return }
        settle(d, p, gen: gen) { [self] _ in
            guard gen == generation else { ready?(exists); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in ready?(exists) }
        }
    }

    /// No viewer, display kept: give the Mac its arrangement back and hide the display behind the
    /// main monitor (mirroring it), so the idle display adds no invisible desktop area.
    private func standby(reason: String) {
        guard exists else { return }
        let target: Arrangement
        if let m = Self.physicalDisplays(excluding: displayID).first(where: { $0 == mainPhysical() }) ?? Self.physicalDisplays(excluding: displayID).first {
            target = .hidden(behind: m)
        } else {
            target = .none
        }
        if setArrangement(target), target != .none { note(action: "idle, hidden behind display \(physicalOf(target) ?? 0) (\(reason))") }
    }

    /// Restores the arrangement and releases the display. With `allowDefer`, a display whose
    /// screens are all asleep is only taken out of service and released at the next wake (macOS
    /// would defer the removal anyway, and a same-identity display can't be created meanwhile).
    private func release(reason: String, allowDefer: Bool) {
        lingerTimer?.cancel(); lingerTimer = nil; lingerUntil = nil
        guard let d = display else { return }
        let id = d.displayID
        _ = setArrangement(.none)
        generation += 1
        ActiveDisplay.setVirtual(nil, mode: nil)
        if allowDefer && Self.allDisplaysAsleep() {
            releaseOnWake = true
            note(action: "display \(id) out of service; removed when the displays wake (\(reason))")
            return
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
    }

    private func screensWoke() {
        guard releaseOnWake, let d = display else { return }
        releaseOnWake = false
        let id = d.displayID
        d.invalidate()
        display = nil
        plan = nil
        note(action: "removed display \(id) (displays woke)")
    }

    /// The system ended the display (WindowServer restart, ...).
    private func terminated(_ gen: Int) {
        guard gen == generation, let d = display else { return }
        note(error: "macOS removed display \(d.displayID)")
        arrangement = .none
        generation += 1
        ActiveDisplay.setVirtual(nil, mode: nil)
        d.invalidate()
        display = nil
        plan = nil
        releaseOnWake = false
        lifecycle.lost()
    }

    private func apply(_ p: VirtualDisplayPlan, to d: GLDVirtualDisplay) throws {
        try d.applyMode(width: UInt32(p.modeWidth), height: UInt32(p.modeHeight), refreshRate: p.refreshRate, hiDPI: p.hiDPI)
    }

    // MARK: Reading the mode back

    /// Waits until macOS shows the planned size, then records the mode it actually uses (capture,
    /// input mapping and DisplayInfo use it).
    ///
    /// The creating process gets no CoreGraphics mode for its own virtual display and AppKit does
    /// not list it, so: CGDisplayBounds (points; reliable in-process) must reach the planned
    /// looks-like size, re-applying the settings once if it doesn't (macOS 27 sometimes ignores the
    /// first settings of a new display), and a child process reads the pixel size
    /// (`glide-host --list-display-modes ID`). Without the child, matching points mean the plan.
    private func settle(_ d: GLDVirtualDisplay, _ p: VirtualDisplayPlan, gen: Int, retried: Bool = false, done: @escaping (DisplayModeInfo) -> Void) {
        let id = d.displayID
        let deadline = Date().addingTimeInterval(2)
        func pointsMatch() -> Bool {
            let b = CGDisplayBounds(id)
            return Int(b.width.rounded()) == p.expected.width && Int(b.height.rounded()) == p.expected.height
        }
        func poll() {
            guard gen == generation, display === d else { return }
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let child = DisplayModeProbe.current(of: id)
                DispatchQueue.main.async {
                    guard let self, gen == self.generation, self.display === d else { return }
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

    private func screenParametersChanged() {
        // Nothing to track: the mode only changes when Glide re-applies settings (settle reads it).
    }

    // MARK: Arrangement

    private var isOnlyDisplay: Bool { Self.physicalDisplays(excluding: displayID).isEmpty }

    /// The main physical display (the one that has the menu bar when the virtual display isn't main).
    private func mainPhysical() -> CGDirectDisplayID? {
        if case let .mirror(p) = arrangement { return p }
        if case let .extendMain(prev) = arrangement { return prev }
        if case let .hidden(p) = arrangement { return p }
        let main = CGMainDisplayID()
        return main == displayID ? nil : main
    }

    private func physicalOf(_ a: Arrangement) -> CGDirectDisplayID? {
        switch a {
        case let .mirror(p), let .hidden(p): return p
        case let .extendMain(p): return p
        case .none: return nil
        }
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
        let ok = Self.configure { cfg in
            switch from {
            case let .mirror(p):
                CGConfigureDisplayMirrorOfDisplay(cfg, p, kCGNullDirectDisplay)
                CGConfigureDisplayOrigin(cfg, p, 0, 0)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { DisplayModeController.shared.restoreAfterMirror(p) }
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
