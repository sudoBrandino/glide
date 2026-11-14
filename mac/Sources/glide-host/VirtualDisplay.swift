import AppKit
import CGlideVirtualDisplay
import CoreGraphics
import GlideCore

/// The optional virtual display (docs/VIRTUAL_DISPLAY.md): a CGVirtualDisplay sized to the viewer,
/// so a headless Mac, or one whose screen doesn't match the viewer, streams pixel-perfect.
///
/// - Opt-in: host.json `"virtualDisplay": {"enabled": true}` or the menu bar.
/// - While it exists it is "the display Glide serves" (ActiveDisplay prefers it), so capture,
///   input mapping and DisplayModeController all follow it like any other CGDirectDisplayID.
/// - Its mode is controlled only through the virtual display's own settings (one mode, HiDPI or
///   not), never with CGConfigureDisplayWithDisplayMode: macOS reports no modes for a virtual display
///   to the process that created it, and a mode switch keeps the display alive until the process exits.
/// - Fails safe: if the private API is missing or creation fails, it logs and Glide keeps serving
///   the physical/main display.
///
/// All state is main-queue confined.
final class VirtualDisplayManager: @unchecked Sendable {
    static let shared = VirtualDisplayManager()

    static let displayName = "Glide Virtual Display"
    /// Arbitrary non-zero IDs (macOS 14+ wants a vendor ID). A stable vendor/product/serial is one
    /// "monitor" to macOS, so its arrangement is remembered across sessions.
    static let vendorID: UInt32 = 0x676C   // "gl"
    static let productID: UInt32 = 0x7664  // "vd"
    static let serialNumber: UInt32 = 1
    static let onlineTimeout: TimeInterval = 4

    private(set) var config = VirtualDisplayConfig()
    private var loaded = false
    private var started = false
    private var lifecycle = VirtualDisplayLifecycle()
    private var display: GLDVirtualDisplay?
    /// The settings applied to `display`.
    private(set) var plan: VirtualDisplayPlan?
    /// The viewer size (or fixed size) `plan` was made for.
    private var plannedFor: (w: Int, h: Int)?
    private var lingerTimer: DispatchWorkItem?
    private var lingerUntil: Date?
    /// The main display before we made the virtual one main.
    private var previousMain: CGDirectDisplayID?
    private var notifiedSinceApply = true
    /// Bumped on every create/destroy/apply so stale async completions do nothing.
    private var generation = 0
    private(set) var lastError: String?
    private(set) var lastAction: String?

    var displayID: CGDirectDisplayID? { display.map(\.displayID).flatMap { $0 == 0 ? nil : $0 } }
    var exists: Bool { displayID != nil }
    static var unavailableReason: String? { GLDVirtualDisplay.unavailableReason() }

    // MARK: Setup

    /// Loads host.json `virtualDisplay` without side effects (also used by --selftest-ui).
    func loadConfig() {
        guard !loaded else { return }
        loaded = true
        if let d = try? Data(contentsOf: HostConfig.url), let c = try? JSONDecoder().decode(HostConfig.self, from: d) {
            config = c.virtualDisplay ?? VirtualDisplayConfig()
        }
        lifecycle = VirtualDisplayLifecycle(enabled: config.isEnabled, alwaysOn: config.alwaysOn, keepAlive: config.keepAlive)
    }

    func start() {
        DispatchQueue.main.async { [self] in
            guard !started else { return }
            started = true
            loadConfig()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.screenParametersChanged()
            }
            guard config.isEnabled else { return }
            log("virtual display: enabled (\(config.alwaysOn ? "always on" : "per session, kept \(Int(config.keepAlive)) s after disconnect")\(config.wantsMain ? ", made main" : ""), \(Int(config.hz)) Hz\(config.fixedSize.map { ", fixed \($0.w)x\($0.h)" } ?? ""))")
            if let why = Self.unavailableReason { log("virtual display: UNAVAILABLE (\(why)); Glide will use the physical display") }
            perform(lifecycle.launched(), reason: "always on")
        }
    }

    // MARK: Hooks from DisplayModeController (main queue)

    /// A viewer authenticated. `ready(exists)` runs on main once the display is online (or right away
    /// if the feature is off, or failed: then Glide serves the physical display).
    func sessionBegan(ready: @escaping (Bool) -> Void) {
        loadConfig()
        perform(lifecycle.sessionBegan(), reason: "viewer connected", ready: ready)
    }

    func sessionEnded() {
        perform(lifecycle.sessionEnded(now: Self.now()), reason: "viewer disconnected")
    }

    func owns(_ id: CGDirectDisplayID) -> Bool { id != 0 && displayID == id }

    /// Applies the display-mode policy to the virtual display: re-applies its settings for the
    /// current viewer size and preference (re-creating it only if the viewer outgrew the limits fixed
    /// at creation). True if its mode changes; the screen-parameters notification then makes the
    /// session re-capture.
    func applyPolicy(reason: String) -> Bool {
        guard let d = display, let cur = plan, let (p, size) = desiredPlan() else { return false }
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
            afterApply()
            return true
        }
        note(action: "re-creating for \(p): larger than the \(d.maxPixelsWide)x\(d.maxPixelsHigh) px limit set at creation (\(reason))")
        destroy(reason: "re-create")
        create(reason: reason, ready: nil)
        return true
    }

    // MARK: Menu (main thread)

    func setEnabled(_ on: Bool) { persist { $0.enabled = on }; reconfigure(reason: on ? "enabled" : "disabled") }
    func setAlwaysOn(_ on: Bool) { persist { $0.lifetime = on ? "always" : "session" }; reconfigure(reason: on ? "always on" : "per session") }
    func setMakeMain(_ on: Bool) {
        persist { $0.makeMain = on }
        guard exists else { return }
        if on { makeMain() } else { undoMain() }
    }

    /// Remove the display now (no viewer connected).
    func removeNow() { perform(lifecycle.removeRequested(), reason: "menu") }

    /// Before quitting: put the arrangement back and remove the display (process exit would remove
    /// it too; this just keeps the log and the arrangement tidy).
    func shutdown() { if exists { destroy(reason: "quit") } }

    var sessionHoldsIt: Bool { lifecycle.phase == .inUse }

    /// One line for the menu.
    var statusLine: String {
        if !config.isEnabled { return "Off" }
        if let why = Self.unavailableReason { return "Unavailable: \(why)" }
        guard let id = displayID, let p = plan else {
            return lastError.map { "Not running — \($0)" } ?? (config.alwaysOn ? "Starting…" : "Created when a viewer connects")
        }
        let m = ActiveDisplay.mode(of: id) ?? p.expected
        var s = (m.hiDPI ? "Looks like \(m.width)×\(m.height) (HiDPI, \(m.pixelWidth)×\(m.pixelHeight) px)" : "\(m.width)×\(m.height) (1x)")
            + " @ \(Int(p.refreshRate.rounded())) Hz"
        if let until = lingerUntil { s += " — removed in \(max(0, Int(until.timeIntervalSinceNow.rounded()))) s" }
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
            create(reason: reason, ready: ready)
        case .destroy:
            destroy(reason: reason)
            ready?(false)
        case let .scheduleTimer(at):
            lingerTimer?.cancel()
            let delay = max(0, at - Self.now())
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lingerTimer = nil
                self.lingerUntil = nil
                self.perform(self.lifecycle.timerFired(now: Self.now()), reason: "no viewer for \(Int(self.config.keepAlive)) s")
            }
            lingerTimer = work
            lingerUntil = Date().addingTimeInterval(delay)
            log("virtual display: keeping it for \(Int(delay)) s in case the viewer reconnects")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            ready?(exists)
        }
    }

    private func reconfigure(reason: String) {
        loadConfig()
        perform(lifecycle.configure(enabled: config.isEnabled, alwaysOn: config.alwaysOn, keepAlive: config.keepAlive, now: Self.now()), reason: reason)
    }

    /// The plan for the current viewer (or the fixed / last / default size) and preference.
    private func desiredPlan() -> (VirtualDisplayPlan, (w: Int, h: Int))? {
        let dm = DisplayModeController.shared
        let size = config.fixedSize ?? dm.viewerSize ?? plannedFor ?? VirtualDisplayConfig.defaultSize
        // "Don't Change": keep whatever the display has (a new display still needs a first mode).
        if dm.effectivePreference == .manual, let p = plan { return (p, plannedFor ?? size) }
        guard let p = VirtualDisplayPlan.make(viewerW: size.w, viewerH: size.h, preference: dm.effectivePreference,
                                              highDPIChoice: dm.settings.highDPIChoice, refreshRate: config.hz) else { return nil }
        return (p, size)
    }

    private func create(reason: String, ready: ((Bool) -> Void)?) {
        if display != nil { destroy(reason: "replaced") }
        func fail(_ msg: String) {
            note(error: msg)
            log("virtual display: falling back to the physical display")
            lifecycle.lost()
            ready?(false)
        }
        if let why = Self.unavailableReason { fail("unavailable: \(why)"); return }
        guard let (wanted, size) = desiredPlan() else { fail("no usable size for the viewer"); return }
        // The physical display goes back to its own mode before the virtual one takes over.
        DisplayModeController.shared.restorePhysicalBeforeVirtual()
        let maxPx = VirtualDisplayPlan.maxPixels(viewerW: size.w, viewerH: size.h, highDPIChoice: DisplayModeController.shared.settings.highDPIChoice, refreshRate: config.hz)
        let mm = wanted.sizeInMillimeters
        generation += 1
        let gen = generation
        let d: GLDVirtualDisplay
        do {
            d = try GLDVirtualDisplay(name: Self.displayName, vendorID: Self.vendorID, productID: Self.productID, serialNumber: Self.serialNumber,
                                      maxPixelsWide: UInt32(maxPx.w), maxPixelsHigh: UInt32(maxPx.h),
                                      sizeInMillimeters: CGSize(width: mm.w, height: mm.h), queue: .main,
                                      onTerminate: { [weak self] in self?.terminated(gen) })
        } catch {
            fail("could not create it: \(error.localizedDescription)"); return
        }
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
        ActiveDisplay.setVirtual(d.displayID, mode: p.expected)
        note(action: "created display \(d.displayID): \(p), limit \(maxPx.w)x\(maxPx.h) px (\(reason))")
        let id = d.displayID
        let deadline = Date().addingTimeInterval(Self.onlineTimeout)
        func poll() {
            guard gen == generation, display != nil else { ready?(exists); return }
            if ActiveDisplay.isOnline(id) {
                // A moment for WindowServer/AppKit to publish the new screen before capture starts.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    guard gen == generation, display != nil else { ready?(exists); return }
                    verifyMode()
                    if config.wantsMain { makeMain() }
                    ready?(true)
                }
            } else if Date() > deadline {
                destroy(reason: "not online")
                fail("display \(id) did not come online within \(Int(Self.onlineTimeout)) s")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }

    private func destroy(reason: String) {
        lingerTimer?.cancel(); lingerTimer = nil; lingerUntil = nil
        guard let d = display else { return }
        let id = d.displayID
        undoMain()
        generation += 1
        ActiveDisplay.setVirtual(nil, mode: nil)
        d.invalidate()
        display = nil
        plan = nil
        note(action: "removed display \(id) (\(reason))")
        // macOS keeps a virtual display whose mode was ever switched until its creator exits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.displayID != id, CGDisplayIsOnline(id) != 0 else { return }
            log("virtual display: display \(id) is still online after release; macOS removes it when glide-host exits")
        }
    }

    /// The system ended the display (WindowServer restart, ...).
    private func terminated(_ gen: Int) {
        guard gen == generation, let d = display else { return }
        note(error: "macOS removed display \(d.displayID)")
        previousMain = nil
        generation += 1
        ActiveDisplay.setVirtual(nil, mode: nil)
        d.invalidate()
        display = nil
        plan = nil
        lifecycle.lost()
    }

    private func apply(_ p: VirtualDisplayPlan, to d: GLDVirtualDisplay) throws {
        notifiedSinceApply = false
        try d.applyMode(width: UInt32(p.modeWidth), height: UInt32(p.modeHeight), refreshRate: p.refreshRate, hiDPI: p.hiDPI)
    }

    /// After re-applying settings: check the result, and make sure the session re-captures even if
    /// macOS didn't post a screen-parameters notification for the change.
    private func afterApply() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, gen == self.generation, self.display != nil else { return }
            self.verifyMode()
            if !self.notifiedSinceApply {
                log("virtual display: no screen-parameters notification after re-applying its settings; re-capturing anyway")
                NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            }
        }
    }

    private func screenParametersChanged() {
        notifiedSinceApply = true
        if let id = displayID, ActiveDisplay.isOnline(id) { verifyMode() }
    }

    /// What macOS actually made of our settings, read through AppKit (CoreGraphics won't report the
    /// modes of our own virtual display). Capture uses this size.
    private func verifyMode() {
        guard let id = displayID, let p = plan else { return }
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else {
            ActiveDisplay.setVirtual(id, mode: p.expected)
            return
        }
        let s = screen.backingScaleFactor, f = screen.frame.size
        let actual = DisplayModeInfo(width: Int(f.width), height: Int(f.height), pixelWidth: Int((f.width * s).rounded()),
                                     pixelHeight: Int((f.height * s).rounded()), refreshRate: p.refreshRate)
        if !actual.sameSize(p.expected) && ActiveDisplay.mode(of: id).map({ !$0.sameSize(actual) }) ?? true {
            log("virtual display: macOS shows \(actual), not the planned \(p.expected); capturing what it shows")
        }
        ActiveDisplay.setVirtual(id, mode: actual)
    }

    // MARK: Main display

    private func makeMain() {
        guard let id = displayID, CGMainDisplayID() != id else { return }
        let prev = CGMainDisplayID()
        if arrange(main: id) {
            previousMain = prev
            note(action: "made display \(id) the main display (was \(prev))")
        } else {
            note(error: "could not make it the main display")
        }
    }

    private func undoMain() {
        guard let prev = previousMain else { return }
        previousMain = nil
        guard let id = displayID, CGMainDisplayID() == id, ActiveDisplay.isOnline(prev) else { return }
        if arrange(main: prev) { log("virtual display: display \(prev) is the main display again") }
    }

    /// Makes `id` the main display by translating the whole arrangement (relative positions kept).
    private func arrange(main id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        var origins: [UInt32: (x: Double, y: Double)] = [:]
        for d in ids.prefix(Int(count)) where CGDisplayMirrorsDisplay(d) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(d)
            origins[d] = (Double(b.origin.x), Double(b.origin.y))
        }
        guard let new = VirtualDisplayArrangement.makingMain(id, origins: origins) else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        for (d, o) in new { CGConfigureDisplayOrigin(cfg, d, Int32(o.x.rounded()), Int32(o.y.rounded())) }
        // forSession: never outlives the login session.
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
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
