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
    check(c.remapModifiers && c.connections.isEmpty && c.pinnedHosts.isEmpty, "viewer.json: defaults")
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
