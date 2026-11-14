import AppKit
import CGlideVirtualDisplay
import CoreGraphics
import GlideCore
@preconcurrency import ScreenCaptureKit

/// `glide-host --list-display-modes [ID]`: prints a display's current mode and its usable modes.
/// Read-only. The virtual-display self-test runs it as a child process, because CoreGraphics reports
/// no modes for a virtual display to the process that created it.
func runListDisplayModes(_ requested: CGDirectDisplayID?) -> Never {
    let id = requested ?? CGMainDisplayID()
    guard CGDisplayIsOnline(id) != 0 else { print("display \(id): not online"); exit(1) }
    let b = CGDisplayBounds(id)
    print("display \(id): main \(CGDisplayIsMain(id) != 0 ? "yes" : "no"), builtin \(CGDisplayIsBuiltin(id) != 0 ? "yes" : "no"), bounds \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height)) pt")
    if let m = CGDisplayCopyDisplayMode(id) {
        // Machine-readable line (parsed by --virtual-display-selftest).
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

/// `glide-host --virtual-display-selftest [--viewer WxH] [--hz N] [--yes]`: creates a temporary
/// virtual display and checks what Glide relies on (docs/VIRTUAL_DISPLAY.md): creation, the HiDPI /
/// 1x mode macOS picks for our single-mode settings, re-applying settings without re-creating,
/// ScreenCaptureKit visibility, and removal on release. Never captures or listens. Only run it
/// explicitly: a new display can rearrange windows while it exists.
func runVirtualDisplaySelfTest(viewer: String?, hz: Double?, skipCountdown: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    setvbuf(stdout, nil, _IOLBF, 0)
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    let parts = (viewer ?? "3840x2160").lowercased().split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 640, parts[1] >= 480 else { print("--viewer wants WxH, e.g. 3840x2160"); exit(2) }
    let (vw, vh) = (parts[0], parts[1])
    let rate = min(max(hz ?? 60, 24), 240)

    print("""
    Glide virtual display self-test
      This CREATES a temporary virtual display ("\(VirtualDisplayManager.displayName)") for about 20 seconds,
      re-applies a few modes, then removes it. While it exists macOS treats it as an extra monitor:
      windows can move and the arrangement in System Settings changes briefly. Nothing is captured
      or sent anywhere. Ctrl-C at any time removes it (the display ends with this process).
      viewer \(vw)x\(vh), \(Int(rate)) Hz, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
    """)
    if let why = GLDVirtualDisplay.unavailableReason() {
        check(false, "private API available: \(why)")
        print("1 FAILURE(S) — Glide would fall back to the physical display")
        exit(1)
    }
    check(true, "private API available (CGVirtualDisplay, Descriptor, Settings, Mode)")
    if !skipCountdown {
        for n in stride(from: 5, through: 1, by: -1) { print("  starting in \(n)… (Ctrl-C to abort)"); sleep(1) }
    }

    func plan(_ p: DisplayModePreference, _ w: Int, _ h: Int) -> VirtualDisplayPlan? {
        VirtualDisplayPlan.make(viewerW: w, viewerH: h, preference: p, highDPIChoice: .retina, refreshRate: rate)
    }
    let maxPx = VirtualDisplayPlan.maxPixels(viewerW: vw, viewerH: vh, highDPIChoice: .retina, refreshRate: rate)
    var steps: [(String, VirtualDisplayPlan)] = []
    if let p = plan(.retina, vw, vh) { steps.append(("retina for \(vw)x\(vh)", p)) }
    if let p = plan(.crisp, vw, vh) { steps.append(("crisp for \(vw)x\(vh) (re-apply, same display)", p)) }
    if let p = plan(.smooth, vw, vh), p.fits(maxPixelsWide: maxPx.w, maxPixelsHigh: maxPx.h) { steps.append(("smooth for \(vw)x\(vh)", p)) }
    let sw = (vw * 2 / 3) & ~7, sh = (vh * 2 / 3) & ~7
    if let p = plan(.crisp, sw, sh) { steps.append(("crisp for a smaller viewer \(sw)x\(sh)", p)) }
    if let p = plan(.retina, vw, vh) { steps.append(("retina again", p)) }
    guard let first = steps.first?.1 else { print("no plan for \(vw)x\(vh)"); exit(2) }

    let before = Set(onlineDisplays())
    let mm = first.sizeInMillimeters
    var terminated = false
    let display: GLDVirtualDisplay
    do {
        display = try GLDVirtualDisplay(name: VirtualDisplayManager.displayName, vendorID: VirtualDisplayManager.vendorID,
                                        productID: VirtualDisplayManager.productID, serialNumber: VirtualDisplayManager.serialNumber,
                                        maxPixelsWide: UInt32(maxPx.w), maxPixelsHigh: UInt32(maxPx.h),
                                        sizeInMillimeters: CGSize(width: mm.w, height: mm.h), queue: .main,
                                        onTerminate: { terminated = true })
    } catch {
        check(false, "create (limit \(maxPx.w)x\(maxPx.h) px): \(error.localizedDescription)")
        print("\(failures) FAILURE(S)")
        exit(1)
    }
    let id = display.displayID
    check(id != 0 && !before.contains(id), "created display \(id) (limit \(maxPx.w)x\(maxPx.h) px)")

    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    func childListing() -> String {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--list-display-modes", "\(id)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "(could not run child: \(error))" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    func childCurrent(_ listing: String) -> DisplayModeInfo? {
        // "current: 1920x1080 px=3840x2160 hz=60"
        guard let line = listing.split(separator: "\n").first(where: { $0.hasPrefix("current: ") }) else { return nil }
        let nums = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 5 else { return nil }
        return DisplayModeInfo(width: nums[0], height: nums[1], pixelWidth: nums[2], pixelHeight: nums[3], refreshRate: Double(nums[4]))
    }
    func screenMode() -> DisplayModeInfo? {
        guard let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return nil }
        let f = s.frame.size, k = s.backingScaleFactor
        return DisplayModeInfo(width: Int(f.width), height: Int(f.height), pixelWidth: Int((f.width * k).rounded()), pixelHeight: Int((f.height * k).rounded()))
    }

    for (i, (name, p)) in steps.enumerated() {
        print("\n[\(i + 1)/\(steps.count)] \(name): mode \(p.modeWidth)x\(p.modeHeight)\(p.hiDPI ? " hiDPI" : "") -> expect \(p.expected)")
        do {
            try display.applyMode(width: UInt32(p.modeWidth), height: UInt32(p.modeHeight), refreshRate: p.refreshRate, hiDPI: p.hiDPI)
            check(true, "applySettings accepted")
        } catch {
            check(false, "applySettings: \(error.localizedDescription)")
            continue
        }
        var online = false
        for _ in 0..<40 { spin(0.1); if CGDisplayIsOnline(id) != 0 { online = true; break } }
        spin(1.5)
        check(online && !terminated, "display online")
        let viaAppKit = screenMode()
        check(viaAppKit.map { $0.sameSize(p.expected) } ?? false, "AppKit (this process) shows \(viaAppKit.map { "\($0)" } ?? "no screen")")
        let listing = childListing()
        let viaChild = childCurrent(listing)
        check(viaChild.map { $0.sameSize(p.expected) } ?? false, "CoreGraphics (child process) reports \(viaChild.map { "\($0) @ \(Int($0.refreshRate)) Hz" } ?? "no mode")")
        if i == 0 {
            print(listing.split(separator: "\n").map { "        " + $0 }.joined(separator: "\n"))
            let ownMode = CGDisplayCopyDisplayMode(id)
            let ownCount = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode])?.count ?? 0
            print("  info this process sees: current mode \(ownMode.map { "\(DisplayModeInfo($0))" } ?? "nil"), \(ownCount) modes (expected nil/0: why Glide tracks the mode itself)")
            let b = CGDisplayBounds(id)
            print("  info bounds \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height)) pt, main display \(CGMainDisplayID())")
        }
    }

    print("\n[ScreenCaptureKit]")
    if CGPreflightScreenCaptureAccess() {
        var listed: Bool?
        Task {
            let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            listed = c?.displays.contains(where: { $0.displayID == id }) ?? false
        }
        for _ in 0..<50 where listed == nil { spin(0.1) }
        check(listed == true, "SCShareableContent lists display \(id) (capturable like any display)")
    } else {
        print("  skip Screen Recording is not granted to this binary (run from the Glide Host.app context to check)")
    }

    print("\n[release]")
    display.invalidate()
    var gone = false
    for _ in 0..<50 { spin(0.1); if CGDisplayIsOnline(id) == 0 { gone = true; break } }
    check(gone, gone ? "display removed after release" : "display still online 5 s after release (macOS keeps it until this process exits)")
    print(failures == 0 ? "\nALL VIRTUAL DISPLAY CHECKS PASSED" : "\n\(failures) FAILURE(S) — please paste this output into an issue")
    exit(failures == 0 ? 0 : 1)
}

private func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}
