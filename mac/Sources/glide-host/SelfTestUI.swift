import AppKit
import GlideCore

/// `glide-host --selftest-ui [--out DIR]`: builds the status menu offscreen for each host state,
/// prints it, writes the menu-bar icons as PNGs, and prints what the display-mode policy would pick
/// on this Mac for common viewers. Read-only: no capture, no network, no display changes, no writes
/// to host.json.
func runSelfTestUI(outDir: String?) -> Never {
    _ = NSApplication.shared
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }

    let dm = DisplayModeController.shared
    dm.loadSettings()
    let modes = dm.modes().map(\.info)
    let cur = dm.currentMode()
    print("display \(dm.displayID): current \(cur.map { "\($0)" } ?? "?"), \(modes.count) usable modes; policy \(dm.settings.preference.rawValue), 4K \(dm.settings.highDPIChoice.rawValue)")
    for (w, h) in [(2560, 1440), (3840, 2160), (1920, 1080), (3440, 1440), (5120, 2880)] {
        var line = "  viewer \(w)x\(h):"
        for p in [DisplayModePreference.automatic, .crisp, .smooth, .retina] {
            let m = DisplayModePolicy.choose(preference: p, viewerW: w, viewerH: h, modes: modes, current: cur, highDPIChoice: dm.settings.highDPIChoice)
            line += "  \(p.rawValue)=\(m.map { "\($0)" } ?? "-")"
        }
        print(line)
    }

    let vd = VirtualDisplayManager.shared
    vd.loadConfig()
    print("virtual display: \(vd.config.isEnabled ? "enabled" : "off"), API \(VirtualDisplayManager.unavailableReason.map { "UNAVAILABLE: \($0)" } ?? "available"); would use:")
    for (w, h) in [(2560, 1440), (3840, 2160), (1920, 1080), (3440, 1440)] {
        let p = VirtualDisplayPlan.make(viewerW: w, viewerH: h, preference: dm.settings.preference, highDPIChoice: dm.settings.highDPIChoice, refreshRate: vd.config.hz)
        print("  viewer \(w)x\(h): \(p.map { "\($0)" } ?? "-")")
    }

    let menu = StatusMenu(actions: .init(), showStatusItem: false)
    let dir = outDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
    if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    let viewer = HostStatus.Viewer(sessionId: 7, name: "DESKTOP-TEST", address: "192.168.10.20", viewW: 2560, viewH: 1440,
                                   video: VideoConfig(width: 2560, height: 1440, codec: .hevc, chroma: .yuv420, scale: 1),
                                   hybrid: true, captureError: nil, fps: 58.4, mbps: 12.3, encodeMs: 7.9, captureMs: 4.2,
                                   latency: LatencyReport(samples: 100, flags: 1, hostUs: 12_000, networkUs: 1_000, queueUs: 100, decodeUs: 1_500,
                                                          renderUs: 300, scanoutUs: 6_900, totalUs: 27_400, groundTruthUs: timingUnknown),
                                   statsAt: Date())
    let paired = [PairedViewer(name: "DESKTOP-TEST", key: Data(repeating: 0xab, count: 32), paired: Date(timeIntervalSince1970: 1_793_970_309))]
    let states: [(String, (inout HostStatus.Snapshot) -> Void, HostStatus.Phase)] = [
        ("idle", { $0 = .init(); $0.listenPort = 7420 }, .idle),
        ("dialing", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; $0.dialDetail = "connection refused" }, .dialing),
        ("connected", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; var v = viewer; v.files = true; $0.viewer = v
            $0.transfers = [.init(incoming: true, files: 3, bytes: 12_300_000, items: [URL(fileURLWithPath: "/tmp")], ok: true, text: nil, date: Date()),
                            .init(incoming: false, files: 0, bytes: 0, items: [], ok: false, text: "Files not sent: the viewer declined (too large)", date: Date())] }, .connected),
        ("error", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; var v = viewer; v.captureError = "Screen Recording not granted"; v.video = nil; v.fps = nil; $0.viewer = v }, .error),
        ("paused", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; $0.paused = true }, .paused),
        ("pairing-open", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; $0.pairingUntil = Date().addingTimeInterval(100); $0.hostFingerprint = "eed3 85a2 4ef7 976a" }, .dialing),
        ("pairing-code", { $0 = .init(); $0.dialTarget = "192.168.10.20:7420"; $0.pairingUntil = Date().addingTimeInterval(80); $0.pairingWith = "DESKTOP-NEW" }, .dialing),
        ("rejected", { $0 = .init(); $0.listenPort = 7420; $0.pairedViewers = paired; $0.hostFingerprint = "eed3 85a2 4ef7 976a"
            $0.note = .init(text: "Rejected unknown viewer “EVIL” (192.168.10.9)", at: Date(), warning: true, count: 3) }, .idle),
    ]
    for (name, set, phase) in states {
        HostStatus.shared.update(set)
        menu.refresh()
        print("\n[\(name)]")
        print(menu.dump())
        check(HostStatus.shared.snapshot.phase == phase, "\(name): phase \(phase.rawValue)")
        let icon = StatusMenu.icon(for: phase)
        check(icon != nil, "\(name): icon")
        if let icon, let dir, let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("icon-\(name).png"))
        }
        let titles = menu.menu.items.filter { !$0.isHidden }.map(\.title)
        check(titles.contains { $0.hasPrefix("Display Mode") } && titles.contains("Open Log") && titles.contains { $0.hasPrefix("Paired Viewers") }, "\(name): core items present")
        check(!titles.contains { $0.localizedCaseInsensitiveContains("password") }, "\(name): no password items (security v2)")
        if name == "idle" { check(titles.contains("Pair New Viewer…"), "idle: pair item") }
        if name == "pairing-open" { check(titles.contains { $0.hasPrefix("Pairing Open — 1:") && $0.hasSuffix("(Cancel)") }, "pairing-open: countdown + cancel") }
        if name == "pairing-code" { check(titles.contains("Pairing with “DESKTOP-NEW” — compare the code…"), "pairing-code: waiting for confirmation") }
        if name == "rejected" {
            check(titles.contains { $0.hasPrefix("⚠︎ Rejected unknown viewer “EVIL” (192.168.10.9) (×3)") }, "rejected: note row")
            check(titles.contains("Paired Viewers (1)"), "rejected: paired count")
            let sub = menu.menu.items.first { $0.title == "Paired Viewers (1)" }?.submenu
            check(sub?.items.first?.title == "DESKTOP-TEST — paired 2026-11-06", "rejected: viewer row")
            check(sub?.items.first?.submenu?.items.contains { $0.title == "Remove…" } == true, "rejected: remove item")
            check(sub?.items.last?.title == "This Mac's key: eed3 85a2 4ef7 976a", "rejected: host key row")
        }
        if name == "connected" {
            check(titles.contains("Viewer: DESKTOP-TEST (192.168.10.20)"), "connected: viewer row")
            check(titles.contains { $0.contains("58 fps") && $0.contains("12.3 Mbps") && $0.contains("encode 7.9 ms") }, "connected: stats row")
            check(menu.menu.items.first { $0.title == "Disconnect Viewer" }?.isEnabled == true, "connected: disconnect enabled")
            check(menu.menu.items.first { $0.title == "Send Files to Viewer…" }?.isEnabled == true, "connected: send files enabled")
            let recent = menu.menu.items.first { $0.title == "Recent Transfers" }?.submenu?.items.map(\.title) ?? []
            check(recent.first?.hasPrefix("Received 3 files · 12 MB") == true && recent.contains("Open Received Files Folder"), "connected: recent transfers \(recent)")
            check(titles.contains("Latency: capture→callback 4.2 · encode 7.9 · glass ~27 ms"), "connected: latency row")
        }
        if name == "paused" { check(titles.contains("Resume Dialing"), "paused: resume item") }
        if name == "idle" { check(menu.menu.items.first { $0.title == "Send Files to Viewer…" }?.isEnabled == false, "idle: send files disabled") }
    }
    // The pairing alert (built, not shown).
    let alert = PairingController.makeAlert(name: "DESKTOP-NEW", fingerprint: "aaa8 fff7 03b5 0b22", address: "192.168.10.20", code: 973_429)
    check(alert.messageText == "Pair “DESKTOP-NEW” with this Mac?" && alert.buttons.map(\.title) == ["Codes Match — Pair", "Cancel"], "pairing alert: title + buttons")
    check((alert.accessoryView as? NSTextField)?.stringValue == "973 429", "pairing alert: code shown as 973 429")
    print("log file: \(StatusMenu.logURL().path)")
    print(failures == 0 ? "UI SELFTEST PASSED" : "\(failures) UI FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
