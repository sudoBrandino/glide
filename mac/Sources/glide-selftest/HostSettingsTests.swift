import Foundation
import GlideCore

/// host.json as the Settings window reads and writes it (GlideCore/HostConfig.swift): defaults,
/// connect-at-launch, listening, PC address validation and Reset Settings.
func hostSettingsTests() throws {
    print("host settings (host.json):")
    let dec = JSONDecoder()
    func decode(_ s: String) throws -> HostConfig { try dec.decode(HostConfig.self, from: Data(s.utf8)) }

    // A file from before the Settings window: today's behavior is kept.
    let old = try decode(#"{"connect": "192.168.1.60:7420", "pairedViewers": [], "clipboard": {"syncConcealed": true}, "futureKey": 1}"#)
    check(old.dialsAtLaunch && old.launchDialTarget(cli: nil) == "192.168.1.60:7420", "settings: an older file still dials the saved PC at launch")
    check(old.clipboard?.isEnabled == true && old.clipboard?.syncsConcealed == true, "settings: clipboard on by default, concealed kept")
    check(old.audio?.isEnabled ?? true, "settings: audio on by default")
    check(ClipboardSettings().isEnabled && !ClipboardSettings().syncsConcealed && AudioSettings().isEnabled, "settings: clipboard/audio defaults")

    // Connect at launch.
    var c = old
    c.connectAtLaunch = false
    check(c.launchDialTarget(cli: nil) == nil, "settings: connectAtLaunch false -> not dialed at launch")
    check(c.launchDialTarget(cli: "10.0.0.5") == "10.0.0.5", "settings: --connect dials even with connectAtLaunch false")
    check(c.launchDialTarget(cli: "  ") == nil, "settings: a blank --connect is ignored")
    c.connectAtLaunch = true
    c.connect = "  "
    check(c.launchDialTarget(cli: nil) == nil, "settings: a blank saved address is not dialed")
    check(HostConfig().launchDialTarget(cli: nil) == nil, "settings: no address -> nothing to dial")

    // Listening (dial-out mode needs an address).
    check(HostConfig().listensAtLaunch(cli: nil, noListenFlag: false), "listen: default listens")
    check(HostConfig(listen: false).listensAtLaunch(cli: nil, noListenFlag: false), "listen: false without an address still listens")
    check(!HostConfig(connect: "pc", listen: false).listensAtLaunch(cli: nil, noListenFlag: false), "listen: false with an address -> dial only")
    check(!HostConfig().listensAtLaunch(cli: "pc", noListenFlag: true), "listen: --connect --no-listen -> dial only")
    check(!HostConfig(connect: "pc", connectAtLaunch: false, listen: false).listensAtLaunch(cli: nil, noListenFlag: false),
          "listen: false is kept when connect-at-launch is off (only this Mac connects, when asked)")

    // Writing: unset keys stay out of the file, and a round trip is lossless.
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let plain = String(decoding: try enc.encode(HostConfig(connect: "pc")), as: UTF8.self)
    check(plain == #"{"connect":"pc"}"#, "write: only set keys are written (\(plain))")
    let full = HostConfig(connect: "[fe80::1]:7420", connectAtLaunch: false, listen: false, display: DisplaySettings(mode: "crisp"),
                          clipboard: ClipboardSettings(enabled: false, syncConcealed: true), audio: AudioSettings(enabled: false),
                          pairedViewers: [PairedViewer(name: "Gaming PC", key: Data(repeating: 0xab, count: 32), paired: Date(timeIntervalSince1970: 0))],
                          files: FileSettings(enabled: true, receive: false, downloadDir: "~/Desktop/In"),
                          virtualDisplay: VirtualDisplayConfig(enabled: false, whenMonitorAttached: "extend"), setupVersion: "0.3.1")
    check(try dec.decode(HostConfig.self, from: enc.encode(full)) == full, "write: every setting survives a round trip")

    // Reset Settings: preferences go, viewers / v1 leftovers / setup / a pending display restore stay.
    var dirty = full
    dirty.salt = "s"; dirty.password = "p"
    let restore = DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
    dirty.display = DisplaySettings(mode: "retina", highDPIViewer: "smooth", restoreOnDisconnect: false, restore: restore, restoreDisplay: 3)
    let reset = dirty.resettingPreferences()
    check(reset.connect == nil && reset.connectAtLaunch == nil && reset.listen == nil && reset.clipboard == nil && reset.audio == nil
          && reset.files == nil && reset.virtualDisplay == nil, "reset: every preference back to its default")
    check(reset.pairedViewers == full.pairedViewers && reset.salt == "s" && reset.password == "p" && reset.setupVersion == "0.3.1",
          "reset: paired viewers, v1 leftovers and finished setup kept")
    check(reset.display == DisplaySettings(restore: restore, restoreDisplay: 3), "reset: display policy cleared, pending restore kept")
    check(reset.display?.preference == .automatic && reset.display?.restoreEnabled == true, "reset: display back to automatic, restore on")
    check(HostConfig(connect: "pc", display: DisplaySettings(mode: "crisp")).resettingPreferences() == HostConfig(),
          "reset: nothing left over when there is nothing to keep")

    // PC address validation (the Settings field) and parsing (the dialer).
    for ok in ["", "  ", "192.168.1.20", "192.168.1.20:7420", "gaming-pc.local", "gaming_pc:1", "[fe80::1]", "[fe80::1%en0]:7420", "fe80::1", "PC:65535"] {
        check(DialPolicy.validateTarget(ok) == nil, "address ok: \"\(ok)\"")
    }
    for bad in ["192.168.1.20:", "pc:0", "pc:70000", "pc:abc", ":7420", "my pc", "[fe80::1", "[fe80::1]7420", "[]:1", "pc/1", "-pc", "fe80::zz"] {
        check(DialPolicy.validateTarget(bad) != nil, "address refused: \"\(bad)\" (\(DialPolicy.validateTarget(bad) ?? "-"))")
    }
    func parsed(_ s: String) -> String? { DialPolicy.parseTarget(s).map { "\($0.host) \($0.port)" } }
    check(parsed("pc") == "pc 7420" && parsed(" pc:7000 ") == "pc 7000" && parsed("[fe80::1]:7421") == "fe80::1 7421"
          && parsed("fe80::1") == "fe80::1 7420" && parsed("") == nil, "address parse: name, port, bracketed and bare IPv6, empty")

    // ConfigFile with the real type: an undecodable host.json is never replaced by a settings change.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-settings-\(getpid())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("host.json")
    let bad = #"{"connectAtLaunch": "no", "pairedViewers": []}"#
    try Data(bad.utf8).write(to: url)
    let refused = (try? ConfigFile.update(url, defaults: { HostConfig() }) { $0.connect = nil }) == nil
    let kept = String(decoding: try Data(contentsOf: url), as: UTF8.self) == bad
    check(refused && kept, "settings: a bad value is refused, the file left as it was")
    try Data(#"{"connect": "pc", "pairedViewers": [{"name": "A", "key": "\#(String(repeating: "ab", count: 32))", "paired": "2026-11-15T18:20:00Z"}]}"#.utf8).write(to: url)
    let after = try ConfigFile.update(url, defaults: { HostConfig() }) { $0 = $0.resettingPreferences() }
    check(after.connect == nil && after.pairedViewers?.map(\.name) == ["A"], "settings: reset on disk keeps the paired viewer")
}
