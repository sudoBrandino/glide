import CoreGraphics
import CryptoKit
import Foundation
import GlideCore

// The Mac viewer (glide-viewer, docs/WINDOWS_HOST.md): viewer.json, pin keys, the identity file,
// Mac key code -> HID mapping with the modifier remap, ClientHello and the other messages it
// sends/receives, pointer normalization, scroll conversion, reconnect timing.

func viewerTests() throws {
    print("mac viewer:")
    viewerTargetTests()
    try viewerConfigTests()
    try viewerConnectionTests()
    try viewerSettingsTests()
    try viewerIdentityTests()
    macKeymapTests()
    try viewerMessageTests()
    viewerPointerTests()
    viewerScrollTests()
    var b = ReconnectBackoff()
    let delays = (0..<7).map { _ in Int(b.next()) }
    b.reset()
    check(delays == [1, 2, 4, 8, 16, 30, 30] && b.next() == 1, "viewer: reconnect backoff 1 s doubling to 30 s, reset \(delays)")
}

private func viewerTargetTests() {
    func key(_ s: String, _ d: UInt16 = ViewerTarget.defaultPort) -> String? { ViewerTarget.parse(s, defaultPort: d)?.pinKey }
    check(key("192.168.1.20") == "192.168.1.20:7421", "target: default port 7421")
    check(key("  Gaming-PC.Local:8000 ") == "gaming-pc.local:8000", "target: trimmed, lowercased, explicit port")
    check(key("[FE80::1]:7421") == "[fe80::1]:7421" && key("[::1]") == "[::1]:7421", "target: bracketed IPv6")
    check(key("fe80::1") == "[fe80::1]:7421", "target: bare IPv6 gets brackets and the default port")
    check(key("host:0") == nil && key("host:x") == nil && key("host:70000") == nil && key("") == nil && key(":7421") == nil && key("[]:1") == nil,
          "target: bad ports / empty hosts rejected")
    check(ViewerTarget.standardPort(platform: "mac") == 7420 && ViewerTarget.standardPort(platform: "windows") == 7421
          && ViewerTarget.standardPort(platform: nil) == 7421, "target: default port per platform")
    check(ViewerTarget.parse("pc")?.display == "pc:7421" && ViewerTarget(host: "::1", port: 9).display == "[::1]:9", "target: display form")
}

private func viewerConfigTests() throws {
    let key = Data(repeating: 0xab, count: 32)
    var c = ViewerConfig()
    check(c.remapModifiers && !c.startFullScreen && c.connections.isEmpty && c.pinnedHosts.isEmpty, "viewer.json: defaults")
    let pc = c.add(name: "Gaming PC", address: "192.168.1.20")
    c.add(name: "Studio Mac", address: "studio.local", platform: "mac")
    c.connections[0].group = "Home"
    c.connections[0].favorite = true
    let t = ViewerTarget.parse("192.168.1.20")!
    c.pin(t, key: key, name: "", at: Date(timeIntervalSince1970: 1_700_000_000))
    c.renamePin(t, key: key, name: "GAMING-PC")
    c.renamePin(t, key: Data(repeating: 1, count: 32), name: "impostor")
    check(c.pinnedKey(for: t) == key && c.pinnedHosts["192.168.1.20:7421"]?.name == "GAMING-PC", "viewer.json: pin keyed by host:port, renamed only for its key")
    check(c.pinnedHosts["192.168.1.20:7421"]?.paired == "2023-11-14T22:13:20Z", "viewer.json: paired timestamp ISO 8601 UTC")
    check(c.pinnedKey(for: ViewerTarget.parse("192.168.1.20:7420")!) == nil, "viewer.json: other port, no pin")

    // Name lookup (case-insensitive) beats address parsing; the Mac connection uses port 7420.
    check(c.resolve("gaming pc")?.target == t && c.resolve("gaming pc")?.connectionID == pc.id, "viewer.json: resolve by name")
    check(c.resolve("studio mac")?.target.pinKey == "studio.local:7420", "viewer.json: mac connection default port 7420")
    check(c.resolve("192.168.1.20:7421")?.connectionID == pc.id, "viewer.json: an address finds its saved connection")
    check(c.resolve("10.0.0.9")?.connectionID == nil, "viewer.json: unknown address resolves without a connection")
    c.markConnected(id: nil, target: t, at: Date(timeIntervalSince1970: 1_800_000_000))
    check(c.connections[0].lastConnected == "2027-01-15T08:00:00Z" && c.connections[1].lastConnected == nil, "viewer.json: lastConnected on the matching connection")

    // JSON round trip.
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let json = try enc.encode(c)
    let back = try JSONDecoder().decode(ViewerConfig.self, from: json)
    check(back == c, "viewer.json: round trip")
    let text = String(decoding: json, as: UTF8.self)
    check(text.contains("\"pinnedHosts\"") && text.contains("\"remapModifiers\"") && text.contains("\"lastConnected\"") && !text.contains("\"port\""),
          "viewer.json: field names per docs/WINDOWS_HOST.md")

    // Tolerant of missing fields; legacy separate port folded into the address.
    let doc = """
    {"connections":[{"name":"A","address":"10.0.0.5"},{"id":"X","name":"B","address":"10.0.0.6","port":9000,"platform":"mac"},
                    {"id":"Y","name":"C","address":"10.0.0.7:7000","port":9000}],
     "pinnedHosts":{"10.0.0.5:7421":{"key":"\(key.hex)"}}}
    """
    let d = try JSONDecoder().decode(ViewerConfig.self, from: Data(doc.utf8))
    check(d.remapModifiers && d.connections.count == 3, "viewer.json: missing keys get defaults")
    check(!d.connections[0].id.isEmpty && d.connections[0].platform == "windows" && !d.connections[0].favorite && d.connections[0].group == nil,
          "viewer.json: connection defaults (id, platform, favorite)")
    let again = try JSONDecoder().decode(ViewerConfig.self, from: Data(doc.utf8))
    check(again.connections.map(\.id) == d.connections.map(\.id), "viewer.json: an entry without an id gets the same id on every read")
    check(d.connections[0].id.count == 36 && d.connections[0].id != d.connections[1].id, "viewer.json: derived ids are UUID-shaped and differ per entry")
    var removed = again
    removed.remove(id: d.connections[0].id)
    check(removed.connections.count == 2, "viewer.json: remove by an id from an earlier read")
    check(d.connections[1].address == "10.0.0.6:9000" && d.connections[2].address == "10.0.0.7:7000", "viewer.json: legacy port folded only when the address has none")
    check(d.pinnedKey(for: ViewerTarget.parse("10.0.0.5")!) == key && d.pinnedHosts["10.0.0.5:7421"]?.name == "", "viewer.json: pin with only a key")
    check((try? JSONDecoder().decode(ViewerConfig.self, from: Data("{}".utf8))) == ViewerConfig(), "viewer.json: empty object")
    for bad in ["{\"pinnedHosts\":[]}", "{\"remapModifiers\":\"yes\"}", "{\"connections\":[{\"favorite\":\"yes\"}]}", "{\"pinnedHosts\":{\"a:1\":{}}}"] {
        check((try? JSONDecoder().decode(ViewerConfig.self, from: Data(bad.utf8))) == nil, "viewer.json: wrong type refused (\(bad))")
    }

    // Through ConfigFile in a scratch folder: forget, remove.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-viewer-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try ViewerPaths.ensureDirectory(dir)
    let url = dir.appendingPathComponent("viewer.json")
    try ConfigFile.write(c, to: url)
    try ConfigFile.update(url, defaults: { ViewerConfig() }) { (v: inout ViewerConfig) in
        v.forget(t)
        v.remove(id: pc.id)
    }
    let after = try ConfigFile.read(ViewerConfig.self, from: url)
    check(after?.pinnedHosts.isEmpty == true && after?.connections.map { $0.name } == ["Studio Mac"], "viewer.json: forget + remove persisted")
}

private func viewerIdentityTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-viewer-id-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("sub/viewer-key")
    let k1 = try ViewerIdentity.loadOrCreate(at: url)
    let k2 = try ViewerIdentity.loadOrCreate(at: url)
    check(k1.rawRepresentation == k2.rawRepresentation, "identity: created once, then loaded")
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          "identity: file 0600, folder 0700")
    let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    check(text.count == 64 && Data(hex: text) == k1.rawRepresentation, "identity: 64 hex characters")
    try Data("not a key\n".utf8).write(to: url)
    var corrupt = false
    do { _ = try ViewerIdentity.loadOrCreate(at: url) } catch ViewerIdentity.Failure.corrupt { corrupt = true }
    let still = try String(contentsOf: url, encoding: .utf8)
    check(corrupt && still == "not a key\n", "identity: corrupt file is an error and is never replaced")
    check(ViewerIdentity.parse(String(repeating: "0", count: 63)) == nil && ViewerIdentity.parse(k1.rawRepresentation.hex + "\n") != nil,
          "identity: parse")
}

private func macKeymapTests() {
    func u(_ code: UInt16, remap: Bool = false, iso: Bool = false) -> UInt16? { MacKeymap.hidUsage(forMacKeyCode: code, iso: iso, remap: remap) }
    check(u(0x00) == 0x04 && u(0x24) == 0x28 && u(0x31) == 0x2C && u(0x7E) == 0x52 && u(0x7A) == 0x3A, "keymap: a, Return, Space, Up, F1")
    check(u(0x2A) == 0x31 && u(0x72) == 0x49 && u(0x69) == 0x46, "keymap: shared Mac keys pick backslash, Insert, Print Screen")
    // Modifiers, as they are and remapped (Command -> Control, Control -> Windows, Option -> Alt).
    check(u(0x37) == 0xE3 && u(0x36) == 0xE7 && u(0x3B) == 0xE0 && u(0x3E) == 0xE4 && u(0x3A) == 0xE2 && u(0x3D) == 0xE6,
          "keymap: modifiers without remap")
    check(u(0x37, remap: true) == 0xE0 && u(0x36, remap: true) == 0xE4, "keymap remap: Command -> Control")
    check(u(0x3B, remap: true) == 0xE3 && u(0x3E, remap: true) == 0xE7, "keymap remap: Control -> Windows")
    check(u(0x3A, remap: true) == 0xE2 && u(0x3D, remap: true) == 0xE6 && u(0x38, remap: true) == 0xE1, "keymap remap: Option -> Alt, Shift unchanged")
    check(u(0x08, remap: true) == 0x06, "keymap remap: letters unchanged (⌘C sends Ctrl + C)")
    check(u(0x0A) == 0x64 && u(0x32) == 0x35 && u(0x0A, iso: true) == 0x35 && u(0x32, iso: true) == 0x64, "keymap: ISO section/grave swap")
    check(u(0x3F) == nil && u(0xFF) == nil, "keymap: Fn and unknown codes not sent")
    // Inverse of HIDKeymap: every Mac code maps to a usage the host maps back to the same code.
    var bad: [String] = []
    for code in MacKeymap.mappedKeyCodes {
        for iso in [false, true] {
            guard let usage = MacKeymap.usage(forMacKeyCode: code, iso: iso), HIDKeymap.macKeyCode(forUsage: usage, iso: iso) == code else {
                bad.append(String(format: "0x%02x%@", code, iso ? "iso" : "")); continue
            }
        }
    }
    check(bad.isEmpty, "keymap: Mac -> HID -> Mac round trip \(bad)")
    var unmapped: [String] = []
    for usage in HIDKeymap.mappedUsages {
        guard let code = HIDKeymap.macKeyCode(forUsage: usage), MacKeymap.usage(forMacKeyCode: code) != nil else { unmapped.append(String(format: "0x%02x", usage)); continue }
    }
    check(unmapped.isEmpty, "keymap: every host-mapped key reachable from a Mac key \(unmapped)")
    // flagsChanged: left/right device bits, generic fallback.
    let lCmd: UInt64 = 0x100000 | 0x08
    check(MacKeymap.modifierIsDown(keyCode: 0x37, flags: lCmd) == true && MacKeymap.modifierIsDown(keyCode: 0x36, flags: lCmd) == false,
          "modifiers: left Command down, right up")
    check(MacKeymap.modifierIsDown(keyCode: 0x37, flags: 0x100000 | 0x10) == false && MacKeymap.modifierIsDown(keyCode: 0x36, flags: 0x100000 | 0x10) == true,
          "modifiers: right Command down, left up")
    check(MacKeymap.modifierIsDown(keyCode: 0x38, flags: 0x20000) == true && MacKeymap.modifierIsDown(keyCode: 0x3B, flags: 0) == false,
          "modifiers: generic mask fallback; released")
    check(MacKeymap.modifierIsDown(keyCode: 0x3E, flags: 0x40000 | 0x2000) == true && MacKeymap.modifierIsDown(keyCode: 0x3D, flags: 0x80000 | 0x40) == true,
          "modifiers: right Control / right Option")
    check(MacKeymap.modifierIsDown(keyCode: 0x39, flags: 0x10000) == nil && MacKeymap.modifierIsDown(keyCode: 0x00, flags: 0) == nil, "modifiers: Caps Lock / non-modifiers")
}

private func viewerMessageTests() throws {
    // Same inputs as windows/src/protocol.rs client_hello_matches_vector_plaintext.
    let rustHello = ClientMessage.hello(version: 1, caps: [.hevc420, .hevc444, .h264], viewW: 3840, viewH: 2160, mode: .fast, maxFps: 60, name: "test-client")
    check(rustHello.encoded.hex == "01010007000000000f7008003c0b00746573742d636c69656e74", "ClientHello matches the Rust viewer's bytes")
    let hello = ViewerHello.message(viewW: 1920, viewH: 1080, maxFps: 60, name: "mac")
    check(hello.encoded.hex == "0102000500000080073804003c03006d6163", "viewer ClientHello: v2, HEVC 4:2:0 + H.264, fast, 60 fps")
    if case let .hello(v, caps, w, h, mode, fps, name) = try ClientMessage.decode(hello.encoded) {
        check(v == 2 && caps == [.hevc420, .h264] && caps.rawValue & ~CodecCaps.codecMask.rawValue == 0 && w == 1920 && h == 1080 && mode == .fast && fps == 60 && name == "mac",
              "viewer ClientHello decodes; no feature bits")
    } else { check(false, "viewer ClientHello decodes") }
    if case let .hello(_, _, w, h, _, fps, _) = ViewerHello.message(viewW: 99_999, viewH: -1, maxFps: 500, name: "x") {
        check(w == UInt16.max && h == 0 && fps == 255, "viewer ClientHello clamps")
    }
    if case let .hello(_, _, _, _, _, fps, _) = ViewerHello.message(viewW: 1, viewH: 1, maxFps: 0, name: "x") { check(fps == 1, "viewer ClientHello: fps at least 1") }

    let refs: [(ClientMessage, String)] = [
        (.key(usage: 0xE0, down: true), "13e00001"),
        (.viewSize(w: 2560, h: 1440), "15000aa005"),
        (.mouseWheel(dx: -0.5, dy: 1), "12000000bf0000803f"),
        (.mouseButton(button: 3, down: true), "110301"),
        (.mouseMove(x: 0.25, y: 0.75), "100000803e0000403f"),
        (.ping(clientTimeUs: 123_456_789), "3015cd5b0700000000"),
        (.releaseAll, "14"),
        (.requestKeyframe, "20"),
        (.pairConfirm(true), "0a01"),
        (.pairConfirm(false), "0a00"),
    ]
    for (m, hex) in refs {
        let back = try? ClientMessage.decode(m.encoded)
        check(m.encoded.hex == hex && back?.encoded.hex == hex, "viewer sends \(hex)")
    }

    // Host -> viewer messages the viewer handles.
    if case .authResult(.unknownViewer)? = try? HostMessage.decode(Data(hex: "0801")!) { check(true, "AuthResult{1} = 08 01") } else { check(false, "AuthResult{1} = 08 01") }
    if case .authResult(.ok)? = try? HostMessage.decode(Data(hex: "0800")!) { check(true, "AuthResult{0}") } else { check(false, "AuthResult{0}") }
    let nonce = Data((0..<32).map { UInt8($0) })
    if case let .pairReveal(n)? = try? HostMessage.decode(Data([0x09]) + nonce) { check(n == nonce, "PairReveal decode") } else { check(false, "PairReveal decode") }
    let bgra = Data((0..<(2 * 3 * 4)).map { UInt8($0) })
    let hostMsgs: [HostMessage] = [
        .cursorShape(id: 7, w: 2, h: 3, hotX: 1, hotY: 2, bgra: bgra),
        .cursorShapeRef(id: 7),
        .cursorPos(x: 0.5, y: 0.25, visible: false),
        .pong(clientTimeUs: 5, hostTimeUs: 9),
        .videoConfig(VideoConfig(width: 1920, height: 1080, codec: .h264, chroma: .yuv420, scale: 1.5)),
        .videoFrame(frameId: 3, captureTimeUs: 77, keyframe: true, data: Data([0, 0, 0, 1, 0x67])),
    ]
    for m in hostMsgs {
        let e = m.encoded
        check((try? HostMessage.decode(e))?.encoded == e, String(format: "host message 0x%02x round trip", e[0]))
    }
    check(HostMessage.cursorPos(x: 0.5, y: 0.25, visible: false).encoded.hex == "410000003f0000803e00", "CursorPos bytes")
    if case let .cursorShape(id, w, h, hx, hy, px)? = try? HostMessage.decode(hostMsgs[0].encoded) {
        check(id == 7 && w == 2 && h == 3 && hx == 1 && hy == 2 && px == bgra, "CursorShape fields")
    } else { check(false, "CursorShape fields") }
    check((try? HostMessage.decode(hostMsgs[0].encoded.dropLast())) == nil, "CursorShape truncated pixels rejected")
}

private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }

private func viewerPointerTests() {
    // Window 960x540 pt on a 2x screen showing a 1920x1080 stream 1:1.
    let r = PointerMath.fitRect(content: CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 960, height: 540))
    check(r == CGRect(x: 0, y: 0, width: 960, height: 540), "pointer: exact fit")
    var n = PointerMath.normalize(CGPoint(x: 0, y: 0), in: r, scale: 2)
    check(near(n.x, 0.5 / 1920) && near(n.y, 0.5 / 1080), "pointer: top-left pixel center")
    n = PointerMath.normalize(CGPoint(x: 0.75, y: 0.5), in: r, scale: 2)
    check(near(n.x, 1.5 / 1920) && near(n.y, 1.5 / 1080), "pointer: second physical pixel")
    n = PointerMath.normalize(CGPoint(x: 959.9, y: 539.9), in: r, scale: 2)
    check(near(n.x, 1919.5 / 1920) && near(n.y, 1079.5 / 1080), "pointer: bottom-right pixel center")
    n = PointerMath.normalize(CGPoint(x: -20, y: 600), in: r, scale: 2)
    check(n.x == 0 && n.y == 1, "pointer: clamped outside the video")
    // Letterboxed: 2:1 video in a square view (bars top and bottom).
    let lb = PointerMath.fitRect(content: CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    check(lb == CGRect(x: 0, y: 250, width: 1000, height: 500), "pointer: letterbox rect")
    n = PointerMath.normalize(CGPoint(x: 500, y: 100), in: lb, scale: 1)
    check(near(n.x, 500.5 / 1000) && n.y == 0, "pointer: over the top bar -> y 0")
    n = PointerMath.normalize(CGPoint(x: 0, y: 350.25), in: lb, scale: 1)
    check(near(n.x, 0.5 / 1000) && near(n.y, 100.5 / 500), "pointer: inside the letterboxed video")
    // Pillarbox (bars left/right).
    let pb = PointerMath.fitRect(content: CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 3000, height: 500))
    check(pb == CGRect(x: 1000, y: 0, width: 1000, height: 500), "pointer: pillarbox rect")
    check(PointerMath.fitRect(content: .zero, in: CGRect(x: 0, y: 0, width: 5, height: 5)).width == 5, "pointer: no video yet -> bounds")
}

private func viewerScrollTests() {
    var s = ScrollAccumulator()
    var o = s.add(dx: 0, dy: 1, precise: false)
    check(o?.dx == 0 && o?.dy == 1, "scroll: wheel up one line -> dy +1 (scroll up)")
    o = s.add(dx: 1, dy: 0, precise: false)
    check(o?.dx == -1 && o?.dy == 0, "scroll: content right -> dx -1 (scroll left)")
    o = s.add(dx: 0, dy: -24, precise: true)
    check(o.map { near($0.dy, -0.5) } == true, "scroll: 24 pt touchpad -> half a notch")
    check(s.add(dx: 0, dy: 0.1, precise: true) == nil, "scroll: under 1/120 notch is held back")
    s.reset()
    var total: Float = 0
    for _ in 0..<48 { if let v = s.add(dx: 0, dy: 1, precise: true) { total += v.dy } }
    check(abs(total - 1) <= 1.0 / 120 + 1e-5, "scroll: 48 × 1 pt adds up to one notch (\(total))")
    check(s.add(dx: .nan, dy: 1, precise: false) == nil, "scroll: NaN ignored")
}

// The Connections window's model (ViewerConnections.swift), mirroring windows/src/connections.rs.
private func viewerConnectionTests() throws {
    let key = Data(repeating: 0xab, count: 32)
    var c = ViewerConfig()
    func draft(_ name: String, _ address: String, port: String = "", group: String = "", favorite: Bool = false) -> ConnectionDraft {
        ConnectionDraft(name: name, address: address, port: port, group: group, favorite: favorite)
    }
    func field(_ r: Result<ValidConnection, ConnectionDraftError>) -> ConnectionField? {
        if case let .failure(e) = r { return e.field }
        return nil
    }
    func value(_ r: Result<ValidConnection, ConnectionDraftError>) -> ValidConnection? { try? r.get() }

    // Validation: trimmed, blank name filled from the address, port folded in, bad input pointed at.
    let v = value(c.validate(draft("  Gaming   PC ", " 192.168.1.20 ", port: " 9000 ", group: "  Home   office ")))
    check(v?.name == "Gaming PC" && v?.address == "192.168.1.20:9000" && v?.group == "Home office", "connections: draft cleaned up, port folded into the address")
    check(value(c.validate(draft("", "192.168.1.20")))?.name == "192.168.1.20" && value(c.validate(draft("", "192.168.1.20")))?.address == "192.168.1.20",
          "connections: blank name = address; no port stays portless (platform default applies)")
    check(value(c.validate(draft("X", "pc.local:8000")))?.address == "pc.local:8000" && value(c.validate(draft("X", "pc.local:8000", port: "8000")))?.address == "pc.local:8000",
          "connections: port in the address, or in both when they agree")
    check(value(c.validate(draft("X", "fe80::1")))?.address == "[fe80::1]" && value(c.validate(draft("X", "fe80::1", port: "7421")))?.address == "[fe80::1]:7421",
          "connections: IPv6 kept in brackets")
    check(value(c.validate(draft("X", "pc", group: "  ")))?.group == nil, "connections: blank group = none")
    check(field(c.validate(draft("X", ""))) == .address && field(c.validate(draft("X", "http://pc"))) == .address
          && field(c.validate(draft("X", "my pc"))) == .address && field(c.validate(draft("X", "pc:0"))) == .address,
          "connections: empty / URL / spaced / bad-port addresses refused")
    check(field(c.validate(draft("X", "pc", port: "0"))) == .port && field(c.validate(draft("X", "pc", port: "70000"))) == .port
          && field(c.validate(draft("X", "pc", port: "abc"))) == .port && field(c.validate(draft("X", "pc:8000", port: "9000"))) == .port,
          "connections: bad port field, or two different ports")
    check(field(c.validate(draft(String(repeating: "n", count: 65), "pc"))) == .name && value(c.validate(draft(String(repeating: "n", count: 64), "pc"))) != nil
          && field(c.validate(draft("X", "pc", group: String(repeating: "g", count: 65)))) == .group, "connections: name / group at most 64 characters")

    // Add, then duplicate names are refused (case-insensitive), except the one being edited.
    guard case let .success(pc) = c.addConnection(draft("Gaming PC", "192.168.1.20", group: "Home")),
          case let .success(laptop) = c.addConnection(draft("Laptop", "10.0.0.5", port: "7500", favorite: true)) else {
        check(false, "connections: add")
        return
    }
    check(pc.platform == "windows" && laptop.address == "10.0.0.5:7500" && laptop.favorite && c.connections.count == 2, "connections: add stores a Windows connection")
    check(field(c.validate(draft("gaming pc", "1.2.3.4"))) == .name && value(c.validate(draft("gaming pc", "1.2.3.4"), editing: pc.id)) != nil,
          "connections: duplicate name refused, own name fine when editing")
    if case .success = c.addConnection(draft("GAMING PC", "1.2.3.4")) { check(false, "connections: add refuses a duplicate name") }

    // Edit form round trip: the address splits into host and port.
    let form = ConnectionDraft(saved: laptop)
    check(form.address == "10.0.0.5" && form.port == "7500" && form.favorite && form.name == "Laptop", "connections: edit form splits address and port")
    check(ConnectionDraft(saved: SavedConnection(name: "V6", address: "[fe80::1]:9")).address == "[fe80::1]"
          && ConnectionDraft(saved: SavedConnection(name: "P", address: "pc")).port == "", "connections: edit form for IPv6 / portless")

    // Update keeps id, platform and last use; a missing id fails.
    c.connections[0].lastConnected = "2026-11-15T22:00:00Z"
    c.connections[0].platform = "mac"
    if case let .failure(e) = c.updateConnection(id: pc.id, draft("Gaming Rig", "192.168.1.21", port: "7421", favorite: true)) { check(false, "connections: update \(e)") }
    let up = c.connections[0]
    check(up.id == pc.id && up.name == "Gaming Rig" && up.address == "192.168.1.21:7421" && up.group == nil && up.favorite
          && up.platform == "mac" && up.lastConnected == "2026-11-15T22:00:00Z", "connections: update replaces the form's fields only")
    if case .success = c.updateConnection(id: "nope", draft("Y", "pc")) { check(false, "connections: update of a removed connection fails") }
    if case .success = c.updateConnection(id: laptop.id, draft("gaming rig", "pc")) { check(false, "connections: rename onto another name refused") }
    c.connections[0].platform = "windows"

    // Duplicate: "(copy)", "(copy 2)", new id, never used.
    let d1 = c.duplicateConnection(id: pc.id), d2 = c.duplicateConnection(id: pc.id)
    let names = c.connections.map(\.name)
    check(names == ["Gaming Rig", "Laptop", "Gaming Rig (copy)", "Gaming Rig (copy 2)"], "connections: duplicate names \(names)")
    let copy = c.connections.first { $0.id == d1 }
    check(d1 != nil && d1 != pc.id && d1 != d2 && copy?.lastConnected == nil && copy?.address == up.address && copy?.favorite == true,
          "connections: duplicate gets a new id and no last use")
    check(c.duplicateConnection(id: "nope") == nil, "connections: duplicate of a missing id")

    // Pairing state, unpair, and remove forgetting the pin only when no other connection shares it.
    let rig = ViewerTarget.parse("192.168.1.21:7421")!
    c.pin(rig, key: key, name: "GAMING-PC", at: Date(timeIntervalSince1970: 1_700_000_000))
    check(c.pairing(for: c.connections[0])?.name == "GAMING-PC" && c.pairing(for: c.connections[1]) == nil, "connections: pairing found by address")
    let removedCopy = c.removeConnection(id: d1!)
    check(removedCopy == RemovedConnection(name: "Gaming Rig (copy)", unpaired: false) && c.pinnedKey(for: rig) == key,
          "connections: removing one of two connections to an address keeps the pin")
    _ = c.removeConnection(id: d2!)
    let removed = c.removeConnection(id: pc.id)
    check(removed == RemovedConnection(name: "Gaming Rig", unpaired: true) && c.pinnedKey(for: rig) == nil, "connections: removing the last one forgets the pin")
    check(c.removeConnection(id: pc.id) == nil, "connections: remove of a missing id")
    let lt = ViewerTarget.parse("10.0.0.5:7500")!
    c.pin(lt, key: key, name: "", at: Date())
    check(c.unpair(id: laptop.id) && c.pinnedKey(for: lt) == nil && !c.unpair(id: laptop.id) && !c.unpair(id: "nope"), "connections: unpair forgets the pin once")
    check(c.connections.map(\.name) == ["Laptop"], "connections: unpair keeps the connection")

    // Rows: grouped (ungrouped first, groups A-Z), favorites first, then by name; filter; status texts.
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00:00Z
    var r = ViewerConfig()
    r.connections = [
        SavedConnection(id: "1", name: "zeta", address: "10.0.0.1", group: "Office"),
        SavedConnection(id: "2", name: "Alpha", address: "10.0.0.2", group: "office", lastConnected: "2027-01-15T07:59:30Z"),
        SavedConnection(id: "3", name: "Mid", address: "10.0.0.3", favorite: true),
        SavedConnection(id: "4", name: "Beta", address: "10.0.0.4", lastConnected: "2027-01-14T07:00:00Z"),
        SavedConnection(id: "5", name: "Fav", address: "10.0.0.5", group: "Home", favorite: true),
        SavedConnection(id: "6", name: "Other", platform: "linux", address: "10.0.0.6"),
        SavedConnection(id: "7", name: "Studio", platform: "mac", address: "studio.local"),
        SavedConnection(id: "8", name: "Broken", address: "bad:port"),
    ]
    r.pin(ViewerTarget.parse("10.0.0.3")!, key: key, name: "MID-PC", at: now)
    r.pin(ViewerTarget.parse("10.0.0.4")!, key: key, name: " ", at: now)
    r.pin(ViewerTarget.parse("studio.local:7420")!, key: key, name: "Studio Mac", at: now)
    r.pinnedHosts["10.0.0.6:7421"] = PinnedHostEntry(key: key.hex, name: "x", paired: "")
    let rows = r.connectionRows(now: now)
    check(rows.map(\.id) == ["3", "4", "8", "6", "7", "5", "2", "1"], "connections: row order \(rows.map(\.id))")
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    check(byID["3"]?.status == "Paired with MID-PC" && byID["3"]?.paired == true && byID["4"]?.status == "Paired" && byID["1"]?.status == "Not paired yet",
          "connections: pairing status texts")
    check(byID["6"]?.supported == false && byID["6"]?.paired == false && byID["6"]?.status == "Not supported by this viewer", "connections: unknown platform shown, not usable")
    check(byID["8"]?.supported == false && byID["8"]?.status == "Invalid address" && byID["8"]?.address == "bad:port", "connections: invalid address shown as is")
    check(byID["7"]?.supported == true && byID["7"]?.status == "Paired with Studio Mac" && byID["7"]?.address == "studio.local:7420",
          "connections: Mac connection uses port 7420")
    check(byID["2"]?.lastUsed == "Just now" && byID["4"]?.lastUsed == "Yesterday" && byID["1"]?.lastUsed == "Never",
          "connections: last used texts")
    check(r.connectionRows(filter: " OFFICE ", now: now).map(\.id) == ["2", "1"] && r.connectionRows(filter: "10.0.0.5", now: now).map(\.id) == ["5"]
          && r.connectionRows(filter: "studio", now: now).map(\.id) == ["7"] && r.connectionRows(filter: "nothing", now: now).isEmpty,
          "connections: filter by group, address, name")
    check(r.connectionGroups == ["Home", "Office"], "connections: distinct groups, case-insensitive \(r.connectionGroups)")

    // Relative times, as the Windows viewer shows them.
    func rel(_ secondsAgo: Int) -> String { ViewerConfig.relativeTime(ViewerConfig.timestamp(now.addingTimeInterval(TimeInterval(-secondsAgo))), now: now) }
    check(rel(0) == "Just now" && rel(59) == "Just now" && rel(60) == "1 minute ago" && rel(150) == "2 minutes ago" && rel(3600) == "1 hour ago"
          && rel(86399) == "23 hours ago" && rel(86400) == "Yesterday" && rel(172_800) == "2 days ago" && rel(29 * 86400) == "29 days ago",
          "connections: relative times")
    check(rel(40 * 86400) == "2026-12-06" && rel(-100) == "Just now" && ViewerConfig.relativeTime("garbage", now: now) == "Unknown",
          "connections: old dates, future, unparsable")

    // Through ViewerStore-style read-modify-write: what Remove/Unpair change persists.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-viewer-conn-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try ViewerPaths.ensureDirectory(dir)
    let url = dir.appendingPathComponent("viewer.json")
    try ConfigFile.write(r, to: url)
    try ConfigFile.update(url, defaults: { ViewerConfig() }) { (v: inout ViewerConfig) in
        _ = v.removeConnection(id: "3")
        v.unpair(id: "7")
        _ = v.duplicateConnection(id: "4")
    }
    let after = try ConfigFile.read(ViewerConfig.self, from: url)
    check(after?.connections.count == 8 && after?.pinnedHosts["10.0.0.3:7421"] == nil && after?.pinnedHosts["studio.local:7420"] == nil
          && after?.pinnedHosts["10.0.0.4:7421"] != nil && after?.connections.last?.name == "Beta (copy)", "connections: changes persisted")
}

private func viewerSettingsTests() throws {
    // startFullScreen: new in this version; older files without it read as off, and round-trip.
    let old = try JSONDecoder().decode(ViewerConfig.self, from: Data("{\"remapModifiers\":false}".utf8))
    check(!old.remapModifiers && !old.startFullScreen, "settings: file without startFullScreen reads as off")
    var c = ViewerConfig()
    c.startFullScreen = true
    c.remapModifiers = false
    let back = try JSONDecoder().decode(ViewerConfig.self, from: try JSONEncoder().encode(c))
    check(back.startFullScreen && !back.remapModifiers, "settings: startFullScreen / remapModifiers round trip")
    check((try? JSONDecoder().decode(ViewerConfig.self, from: Data("{\"startFullScreen\":1}".utf8))) == nil, "settings: wrong type refused")
}
