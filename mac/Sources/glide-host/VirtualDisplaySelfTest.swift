import AppKit
import CGlideVirtualDisplay
import CoreGraphics
import GlideCore
@preconcurrency import ScreenCaptureKit

/// `glide-host --list-display-modes [ID]`: prints a display's current mode and its usable modes.
/// Read-only. The host runs it as a child process (DisplayModeProbe) to read its own virtual
/// display's mode, because CoreGraphics reports no modes for a virtual display to the process that
/// created it.
func runListDisplayModes(_ requested: CGDirectDisplayID?) -> Never {
    let id = requested ?? CGMainDisplayID()
    guard CGDisplayIsOnline(id) == 1 else { print("display \(id): not online"); exit(1) }
    let b = CGDisplayBounds(id)
    print("display \(id): main \(CGDisplayIsMain(id) != 0 ? "yes" : "no"), builtin \(CGDisplayIsBuiltin(id) != 0 ? "yes" : "no"), bounds \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height)) pt")
    if let m = CGDisplayCopyDisplayMode(id) {
        // Machine-readable line (DisplayModeInfo.parseListing).
        print("current: \(m.width)x\(m.height) px=\(m.pixelWidth)x\(m.pixelHeight) hz=\(Int(m.refreshRate.rounded()))")
    } else {
        print("current: unknown")
    }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = ((CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
    print("usable modes: \(modes.count)")
    for m in modes { print("  \(DisplayModeInfo(m)) @ \(Int(m.refreshRate.rounded())) Hz") }
    exit(0)
}

// MARK: - Self-test (observer)

/// `glide-host --virtual-display-selftest [--viewer WxH] [--hz N] [--yes]`: checks what the host
/// relies on (docs/VIRTUAL_DISPLAY.md). A worker child process creates the displays, exactly like
/// the host would, and reports what the host would conclude; this process observes from outside
/// (where CoreGraphics reports a virtual display's real mode) and checks:
///
/// - creation with Glide's identity and 6K limits;
/// - each mode (Retina, Crisp, Smooth, a smaller viewer, Retina again): the host's read-back
///   (CGDisplayBounds + child probe) matches the plan and what CoreGraphics reports here;
/// - ScreenCaptureKit lists it (in the creating process, as the host captures it);
/// - mirroring with a stand-in virtual "monitor" (the transactions Glide uses; no physical display
///   is touched: the test never sets an origin and checks every physical display before and after);
/// - removal on release, and that nothing lingers after the worker exits (one display is left
///   unreleased on purpose, like a crash).
///
/// The displays are kept awake for the test: macOS defers removing a virtual display while every
/// display sleeps, until the next wake. Never captures the screen or listens.
func runVirtualDisplaySelfTest(viewer: String?, hz: Double?, skipCountdown: Bool) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    // CoreGraphics only learns about display changes while this process runs its run loop: without
    // it, the display list and modes stay as they were at the first query (no new display, no mode,
    // a removed display still "online"). Every wait below spins the run loop.
    _ = NSApplication.shared
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
    let parts = (viewer ?? "3840x2160").lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 640, parts[1] >= 480 else { print("--viewer wants WxH, e.g. 3840x2160"); exit(2) }
    let rate = min(max(hz ?? 60, 24), 240)

    print("""
    Glide virtual display self-test
      This CREATES two temporary virtual displays ("\(VirtualDisplayManager.displayName)" and a stand-in monitor)
      for about 30 seconds, re-applies a few modes, mirrors them with each other, then removes them.
      While they exist macOS treats them as extra monitors beside yours; your monitors' modes and
      arrangement are not changed (checked). Nothing is captured or sent anywhere. Ctrl-C at any time
      ends the test (macOS removes the displays when the worker exits while the displays are awake).
      viewer \(parts[0])x\(parts[1]), \(Int(rate)) Hz, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
    """)
    if let why = GLDVirtualDisplay.unavailableReason() {
        check(false, "private API available: \(why)")
        print("1 FAILURE(S) — Glide would fall back to the physical display")
        exit(1)
    }
    check(true, "private API available (CGVirtualDisplay, Descriptor, Settings, Mode)")
    let stale = VirtualDisplayManager.staleDisplays(excluding: 0)
    if !stale.isEmpty {
        print("  note Glide virtual display(s) \(stale.map(String.init).joined(separator: ", ")) already online (a running host, or left over while the displays slept)")
    }
    if !skipCountdown {
        for n in stride(from: 5, through: 1, by: -1) { print("  starting in \(n)… (Ctrl-C to abort)"); sleep(1) }
    }

    // Keep the displays awake: removal of a virtual display is deferred while every display sleeps.
    let wasAsleep = VirtualDisplayManager.allDisplaysAsleep()
    Power.wakeDisplay()
    let awake = Power.preventDisplaySleep()
    if wasAsleep {
        print("  note every display was asleep: woke them (macOS only removes virtual displays while a display is awake)")
        for _ in 0..<30 where VirtualDisplayManager.allDisplaysAsleep() { spin(0.1) }
    }
    defer { Power.release(awake) }

    // A display's mode as a fresh process sees it (DisplayModeProbe, like the host's read-back):
    // CoreGraphics gives no mode for a display that appeared after a process's first display query
    // (here: the worker's displays), and keeps stale state for it, even with the run loop running.
    func cgMode(_ id: CGDirectDisplayID) -> DisplayModeInfo? { DisplayModeProbe.current(of: id) }

    // Physical displays before: none of them may change.
    struct Snap: Equatable { let bounds: CGRect; let mode: DisplayModeInfo?; let mirrors: CGDirectDisplayID }
    func snapshot() -> [CGDirectDisplayID: Snap] {
        var s: [CGDirectDisplayID: Snap] = [:]
        for id in VirtualDisplayManager.physicalDisplays(excluding: nil) {
            s[id] = Snap(bounds: CGDisplayBounds(id), mode: cgMode(id), mirrors: CGDisplayMirrorsDisplay(id))
        }
        return s
    }
    let physicalBefore = snapshot(), mainBefore = CGMainDisplayID()
    print("  info physical displays: " + (physicalBefore.isEmpty ? "none" : physicalBefore.keys.sorted().map { "\($0) \(physicalBefore[$0]!.mode.map { "\($0)" } ?? "?")" }.joined(separator: "; ")) + ", main \(mainBefore)")
    func physicalUnchanged(_ when: String) {
        let now = snapshot()
        check(now == physicalBefore && CGMainDisplayID() == mainBefore, "physical displays unchanged (\(when))")
    }

    // The worker.
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let worker = Process()
    worker.executableURL = exe
    worker.arguments = ["--virtual-display-selftest-worker", "--viewer", "\(parts[0])x\(parts[1])", "--hz", "\(Int(rate))"]
    let toWorker = Pipe(), fromWorker = Pipe()
    worker.standardInput = toWorker
    worker.standardOutput = fromWorker
    do { try worker.run() } catch { check(false, "start the worker: \(error)"); exit(1) }
    signal(SIGINT) { _ in exit(130) }  // the worker gets SIGINT from the terminal too and exits
    let lines = LineReader(fromWorker.fileHandleForReading)
    func next() { spin(0.3); toWorker.fileHandleForWriting.write(Data("next\n".utf8)) }
    var created: [CGDirectDisplayID] = []
    var standIn: CGDirectDisplayID = 0
    var standInMode: DisplayModeInfo?

    while let line = lines.next(spin: { spin(0.05) }) {
        spin(0.2)  // let this process see the worker's latest change
        let f = line.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = f.count > 1 ? f[1] : ""
        switch f.first ?? "" {
        case "INFO":
            print("  info \(rest)")
        case "SECTION":
            print("\n[\(rest)]")
        case "CHECK":
            let ok = rest.hasPrefix("ok ")
            check(ok, String(rest.dropFirst(ok ? 3 : 5)))
        case "CREATED":  // CREATED id role
            let a = rest.split(separator: " ")
            if let id = UInt32(a[0]) {
                created.append(id)
                if a.count > 1, a[1] == "standin" {
                    standIn = id
                    standInMode = cgMode(id)
                    print("  info stand-in monitor \(id): \(standInMode.map { "\($0)" } ?? "no mode")")
                    next()
                }
            }
        case "STEP":  // STEP id expect=w,h,pw,ph readback=w,h,pw,ph
            let kv = Dictionary(uniqueKeysWithValues: rest.split(separator: " ").dropFirst().compactMap { p -> (String, [Int])? in
                let s = p.split(separator: "="); guard s.count == 2 else { return nil }
                return (String(s[0]), s[1].split(separator: ",").compactMap { Int($0) })
            })
            let id = UInt32(rest.split(separator: " ").first ?? "") ?? 0
            func info(_ a: [Int]?) -> DisplayModeInfo? { a.flatMap { $0.count == 4 ? DisplayModeInfo(width: $0[0], height: $0[1], pixelWidth: $0[2], pixelHeight: $0[3]) : nil } }
            let expect = info(kv["expect"]), readback = info(kv["readback"]), truth = cgMode(id)
            check(expect != nil && readback.map { $0.sameSize(expect!) } == true, "host read-back (CGDisplayBounds + probe) is the plan: \(readback.map { "\($0)" } ?? "none")")
            check(expect != nil && truth.map { $0.sameSize(expect!) } == true, "CoreGraphics (outside the creator) reports \(truth.map { "\($0) @ \(Int($0.refreshRate.rounded())) Hz" } ?? "no mode")")
            if let t = truth, let e = expect, Int(t.refreshRate.rounded()) != Int(rate.rounded()), t.sameSize(e) {
                print("  info refresh \(Int(t.refreshRate.rounded())) Hz instead of \(Int(rate)) Hz")
            }
            next()
        case "MIRRORED":  // MIRRORED slave master
            let a = rest.split(separator: " ").compactMap { UInt32($0) }
            if a.count == 2 {
                check(CGDisplayMirrorsDisplay(a[0]) == a[1], "display \(a[0]) mirrors display \(a[1])")
                let sm = cgMode(a[0]), mm = cgMode(a[1])
                print("  info mirror slave mode \(sm.map { "\($0)" } ?? "?"), master \(mm.map { "\($0)" } ?? "?") (macOS gives the slave a matching mode)")
                physicalUnchanged("mirror")
            }
            next()
        case "UNMIRRORED":
            let a = rest.split(separator: " ").compactMap { UInt32($0) }
            check(a.allSatisfy { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }, "mirror ended")
            spin(1)  // macOS gives the slave its mode back asynchronously
            if standIn != 0, let before = standInMode {
                let now = cgMode(standIn)
                // macOS gives a former mirror slave its *persisted* preferred mode, which need not be
                // the mode it had (a .forSession switch, or here a new display's first default). The
                // host then puts the remembered mode back (DisplayModeController.restoreAfterMirror).
                let same = now.map { $0.sameSize(before) } == true
                print("  info after the mirror the stand-in monitor is \(now.map { "\($0)" } ?? "?") (was \(before))" + (same ? "" : ": macOS restored its persisted mode, not the previous one; the host restores the remembered mode in that case"))
            }
            physicalUnchanged("unmirror")
            next()
        case "RELEASED":  // RELEASED id
            let id = UInt32(rest) ?? 0
            var gone = false
            for _ in 0..<50 { if !VirtualDisplayManager.onlineDisplays().contains(id) { gone = true; break }; spin(0.1) }
            check(gone, gone ? "display \(id) removed after release" : "display \(id) still online 5 s after release\(VirtualDisplayManager.allDisplaysAsleep() ? " (displays asleep)" : "")")
            next()
        case "EXITING":
            print("  info worker exiting without releasing display \(rest) (like a crash)")
            next()
        default:
            print("  \(line)")
        }
    }
    while worker.isRunning { spin(0.1) }
    print("\n[after the worker exited (status \(worker.terminationStatus))]")
    func lingering() -> [CGDirectDisplayID] {
        VirtualDisplayManager.onlineDisplays().filter { created.contains($0) || (VirtualDisplayManager.isGlideDisplay($0) && !stale.contains($0)) }
    }
    var left = lingering()
    for _ in 0..<50 where !left.isEmpty { spin(0.1); left = lingering() }
    if left.isEmpty {
        check(true, "no test display lingers after the worker exited")
    } else {
        check(false, "display(s) \(left.map(String.init).joined(separator: ", ")) LINGER after the worker exited\(VirtualDisplayManager.allDisplaysAsleep() ? " (every display is asleep)" : "")")
        print("  info waking the displays to let macOS finish the removal…")
        Power.wakeDisplay()
        for _ in 0..<50 where !lingering().isEmpty { spin(0.1) }
        let still = lingering()
        print(still.isEmpty ? "  info waking the displays removed them" : "  info still online: \(still.map(String.init).joined(separator: ", ")); they disappear at logout or reboot (please report this)")
    }
    physicalUnchanged("end")
    print(failures == 0 ? "\nALL VIRTUAL DISPLAY CHECKS PASSED" : "\n\(failures) FAILURE(S) — please paste this output into an issue")
    exit(failures == 0 ? 0 : 1)
}

/// Reads lines from a pipe on a background thread; `next(spin:)` keeps the caller's run loop going
/// while it waits.
private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var eof = false
    init(_ h: FileHandle) {
        Thread.detachNewThread { [self] in
            var buf = Data()
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                buf.append(d)
                while let i = buf.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf[buf.startIndex..<i], as: UTF8.self)
                    buf.removeSubrange(buf.startIndex...i)
                    lock.withLock { lines.append(line) }
                }
            }
            lock.withLock {
                if !buf.isEmpty { lines.append(String(decoding: buf, as: UTF8.self)) }
                eof = true
            }
        }
    }
    func next(spin: () -> Void) -> String? {
        while true {
            let (line, done): (String?, Bool) = lock.withLock { (lines.isEmpty ? nil : lines.removeFirst(), eof) }
            if let line { return line }
            if done { return nil }
            spin()
        }
    }
}

// MARK: - Self-test worker (creator)

/// The self-test's child: creates the displays the way the host does and reports, line by line,
/// what the host would conclude. Waits for "next" on stdin after each step so the observer can
/// look from outside.
func runVirtualDisplaySelfTestWorker(viewer: String?, hz: Double?) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    setvbuf(stdout, nil, _IOLBF, 0)
    func say(_ s: String) { print(s); fflush(stdout) }
    func waitNext() { _ = readLine() }
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func info(_ m: DisplayModeInfo?) -> String { m.map { "\($0.width),\($0.height),\($0.pixelWidth),\($0.pixelHeight)" } ?? "-" }

    let parts = (viewer ?? "3840x2160").lowercased().split(separator: "x").compactMap { Int($0) }
    let (vw, vh) = (parts[0], parts[1])
    let rate = min(max(hz ?? 60, 24), 240)
    func plan(_ p: DisplayModePreference, _ w: Int, _ h: Int) -> VirtualDisplayPlan? {
        VirtualDisplayPlan.make(viewerW: w, viewerH: h, preference: p, highDPIChoice: .retina, refreshRate: rate)
    }
    let limits = VirtualDisplayPlan.creationLimits(viewerW: vw, viewerH: vh, highDPIChoice: .retina)
    var steps: [(String, VirtualDisplayPlan)] = []
    if let p = plan(.retina, vw, vh) { steps.append(("retina for \(vw)x\(vh)", p)) }
    if let p = plan(.crisp, vw, vh) { steps.append(("crisp for \(vw)x\(vh) (re-apply, same display)", p)) }
    if let p = plan(.smooth, vw, vh), p.fits(maxPixelsWide: limits.w, maxPixelsHigh: limits.h) { steps.append(("smooth for \(vw)x\(vh)", p)) }
    let sw = (vw * 2 / 3) & ~7, sh = (vh * 2 / 3) & ~7
    if let p = plan(.crisp, sw, sh) { steps.append(("crisp for a smaller viewer \(sw)x\(sh)", p)) }
    if let p = plan(.retina, vw, vh) { steps.append(("retina again", p)) }
    guard let first = steps.first?.1 else { say("CHECK fail no plan for \(vw)x\(vh)"); exit(2) }

    var terminated = false
    func make(name: String, serials: [UInt32], limits: (w: Int, h: Int), mm: (w: Double, h: Double)) -> (GLDVirtualDisplay, UInt32)? {
        var last: Error?
        for s in serials {
            do {
                let d = try GLDVirtualDisplay(name: name, vendorID: VirtualDisplayManager.vendorID, productID: VirtualDisplayManager.productID, serialNumber: s,
                                              maxPixelsWide: UInt32(limits.w), maxPixelsHigh: UInt32(limits.h),
                                              sizeInMillimeters: CGSize(width: mm.w, height: mm.h), queue: .main, onTerminate: { terminated = true })
                return (d, s)
            } catch { last = error }
        }
        say("CHECK fail create \(name): \(last?.localizedDescription ?? "?")")
        return nil
    }
    func apply(_ d: GLDVirtualDisplay, _ p: VirtualDisplayPlan) -> Bool {
        do { try d.applyMode(width: UInt32(p.modeWidth), height: UInt32(p.modeHeight), refreshRate: p.refreshRate, hiDPI: p.hiDPI); return true } catch {
            say("CHECK fail applySettings \(p): \(error.localizedDescription)"); return false
        }
    }
    /// The host's read-back (VirtualDisplayManager.settle), synchronously.
    func readBack(_ d: GLDVirtualDisplay, _ p: VirtualDisplayPlan) -> DisplayModeInfo {
        let id = d.displayID
        func pointsMatch() -> Bool { let b = CGDisplayBounds(id); return Int(b.width) == p.expected.width && Int(b.height) == p.expected.height }
        var ok = false
        for _ in 0..<20 { spin(0.1); if pointsMatch() { ok = true; break } }
        if !ok {
            let b = CGDisplayBounds(id)
            say("INFO macOS shows \(Int(b.width))x\(Int(b.height)) pt, not \(p.expected.width)x\(p.expected.height); re-applying the settings (as the host does)")
            _ = apply(d, p)
            for _ in 0..<20 { spin(0.1); if pointsMatch() { break } }
        }
        spin(0.3)
        let b = CGDisplayBounds(id)
        return VirtualDisplayManager.conclude(boundsW: Int(b.width.rounded()), boundsH: Int(b.height.rounded()), child: DisplayModeProbe.current(of: id), plan: p)
    }
    func mirror(_ slave: CGDirectDisplayID, of master: CGDirectDisplayID, unmirror: [CGDirectDisplayID] = []) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        for u in unmirror { CGConfigureDisplayMirrorOfDisplay(cfg, u, kCGNullDirectDisplay) }
        if slave != 0 { CGConfigureDisplayMirrorOfDisplay(cfg, slave, master) }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    say("SECTION create")
    guard let (display, serial) = make(name: VirtualDisplayManager.displayName, serials: VirtualDisplayManager.serialNumbers, limits: limits, mm: first.sizeInMillimeters) else { exit(1) }
    let id = display.displayID
    say("CREATED \(id) glide")
    say("CHECK \(id != 0 ? "ok" : "fail") created display \(id) (serial \(serial), limit \(limits.w)x\(limits.h) px)")
    if serial != VirtualDisplayManager.serialNumbers[0] { say("INFO serial \(VirtualDisplayManager.serialNumbers[0]) was taken by a leftover display (the host falls back the same way)") }

    for (i, (name, p)) in steps.enumerated() {
        say("SECTION \(i + 1)/\(steps.count) \(name): mode \(p.modeWidth)x\(p.modeHeight)\(p.hiDPI ? " hiDPI" : "") @ \(Int(p.refreshRate)) Hz -> expect \(p.expected)")
        guard apply(display, p) else { continue }
        var online = false
        for _ in 0..<40 { spin(0.1); if ActiveDisplay.isOnline(id) { online = true; break } }
        say("CHECK \(online && !terminated ? "ok" : "fail") display online")
        let r = readBack(display, p)
        if i == 0 {
            let own = CGDisplayCopyDisplayMode(id)
            say("INFO in the creating process CoreGraphics reports \(own.map { "\(DisplayModeInfo($0))" } ?? "no mode") and AppKit lists \(NSScreen.screens.contains { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } ? "it" : "no screen for it") (why the host reads back via CGDisplayBounds + a child)")
        }
        say("STEP \(id) expect=\(info(p.expected)) readback=\(info(r))")
        waitNext()
    }

    say("SECTION ScreenCaptureKit (in the creating process, as the host captures)")
    if CGPreflightScreenCaptureAccess() {
        var listed: Bool?
        Task {
            let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            listed = c?.displays.contains(where: { $0.displayID == id }) ?? false
        }
        for _ in 0..<50 where listed == nil { spin(0.1) }
        say("CHECK \(listed == true ? "ok" : "fail") SCShareableContent lists display \(id)")
    } else {
        say("INFO skip: Screen Recording is not granted to this binary (run it from the Glide Host.app context to check)")
    }

    say("SECTION mirroring (with a stand-in virtual monitor; no physical display is touched)")
    let monitorPlan = VirtualDisplayPlan(modeWidth: 3840, modeHeight: 2160, hiDPI: false, refreshRate: 60, style: .crisp)
    guard let (standIn, _) = make(name: "Glide Self-Test Monitor", serials: [9, 10], limits: (3840, 2160), mm: (700, 394)) else { exit(1) }
    let a = standIn.displayID
    _ = apply(standIn, monitorPlan)
    let sr = readBack(standIn, monitorPlan)
    say("INFO stand-in read back as \(sr) (asked for \(monitorPlan.expected))")
    say("CREATED \(a) standin")
    waitNext()
    let p0 = steps.last!.1
    say("CHECK \(mirror(a, of: id) ? "ok" : "fail") the monitor mirrors the virtual display (streaming arrangement, one transaction)")
    spin(2)
    say("MIRRORED \(a) \(id)")
    waitNext()
    say("CHECK \(mirror(id, of: a, unmirror: [a]) ? "ok" : "fail") swap: the virtual display mirrors the monitor (idle, hidden; one transaction)")
    spin(2)
    say("MIRRORED \(id) \(a)")
    waitNext()
    say("CHECK \(mirror(0, of: 0, unmirror: [id]) ? "ok" : "fail") unmirror")
    spin(2)
    say("UNMIRRORED \(a) \(id)")
    waitNext()
    _ = apply(display, p0)  // what the host does after leaving the hidden state
    let r = readBack(display, p0)
    say("SECTION after the mirror: the virtual display's own settings again")
    say("STEP \(id) expect=\(info(p0.expected)) readback=\(info(r))")
    waitNext()

    say("SECTION release (displays awake)")
    display.invalidate()
    say("RELEASED \(id)")
    waitNext()
    say("SECTION exit")
    say("EXITING \(a)")
    waitNext()
    _ = standIn  // deliberately not released: process exit must remove it
    exit(0)
}

extension VirtualDisplayManager {
    /// The mode the host records for its virtual display (VirtualDisplayManager.settle): the child
    /// probe's mode if its point size matches CGDisplayBounds, else the plan if the points match,
    /// else what the bounds show at 1x.
    static func conclude(boundsW bw: Int, boundsH bh: Int, child: DisplayModeInfo?, plan p: VirtualDisplayPlan) -> DisplayModeInfo {
        if bw <= 0 || bh <= 0 { return p.expected }
        if var m = child, m.width == bw, m.height == bh {
            if m.refreshRate <= 0 { m.refreshRate = p.refreshRate }
            return m
        }
        if bw == p.expected.width && bh == p.expected.height { return p.expected }
        return DisplayModeInfo(width: bw, height: bh, pixelWidth: bw, pixelHeight: bh, refreshRate: p.refreshRate)
    }
}
