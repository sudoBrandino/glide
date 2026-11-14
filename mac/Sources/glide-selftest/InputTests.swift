import CoreGraphics
import Foundation
import GlideCore

// Input (PROTOCOL.md §3, §3.6): wire vectors (docs/input-vectors.json) and the injector's pure
// logic — pointer mapping, click counting, scroll conversion, keymap.

struct InputVectors: Decodable {
    struct Msg: Decodable { let name: String; let hex: String }
    let messages: [Msg]
}

func inputTests(vectorsDir: URL) throws {
    try inputWireTests(vectorsDir: vectorsDir)
    pointerMappingTests()
    clickCounterTests()
    scrollConverterTests()
    keymapTests()
}

private func inputWireTests(vectorsDir: URL) throws {
    let v = try JSONDecoder().decode(InputVectors.self, from: Data(contentsOf: vectorsDir.appendingPathComponent("input-vectors.json")))
    let client: [String: ClientMessage] = [
        "ScrollPrecise": .scroll(precise: true, dx: 0, dy: 0.25),
        "ScrollDiscrete": .scroll(precise: false, dx: -1, dy: 0),
        "MouseDelta": .mouseDelta(dx: 5, dy: -3),
        "LockState": .keyExtra(.lockState(KeyExtra.capsLock)),
        "ConsumerKey": .keyExtra(.consumerKey(usage: 0xCD, down: true)),
    ]
    check(client.count + 1 == v.messages.count, "input vectors: one case per reference message")
    for m in v.messages {
        guard let want = Data(hex: m.hex) else { check(false, "input vector \(m.name) hex"); continue }
        if m.name == "InputCaps" {
            var ok = HostMessage.inputCaps(.all).encoded == want
            if case let .inputCaps(c)? = try? HostMessage.decode(want) { ok = ok && c == .all } else { ok = false }
            check(ok, "input vector InputCaps encode/decode")
            continue
        }
        guard let msg = client[m.name] else { check(false, "input vector \(m.name) known"); continue }
        let back = try? ClientMessage.decode(want)
        check(msg.encoded == want && back.map { $0.encoded == want } == true, "input vector \(m.name) encode/decode")
    }
    // Unknown KeyExtra kinds decode (and are ignored), truncated messages don't.
    if case .keyExtra(.unknown(kind: 7))? = try? ClientMessage.decode(Data([0x19, 7, 1, 2])) { check(true, "KeyExtra unknown kind decodes") }
    else { check(false, "KeyExtra unknown kind decodes") }
    var truncOK = true
    for m in v.messages { if let d = Data(hex: m.hex), d.count > 1 { for n in 1..<d.count where (try? ClientMessage.decode(d.prefix(n))) != nil && d[0] != 0x44 { truncOK = false } } }
    check(truncOK, "input messages: truncation rejected")
    check(CodecCaps.inputExt.rawValue == 1 << 12, "caps bit 12 = input extensions")
}

private func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps }

private func pointerMappingTests() {
    // A 2x Retina display of 1512x982 points, as the main display.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    check(near(PointerMapping.point(x: 0, y: 0, in: main), CGPoint(x: 0, y: 0)), "pointer: 0,0 -> top-left corner")
    check(near(PointerMapping.point(x: 0.5, y: 0.5, in: main), CGPoint(x: 756, y: 491)), "pointer: center maps to the exact center (old -1 math: 755.5, 490.5)")
    check(near(PointerMapping.point(x: 1, y: 1, in: main), CGPoint(x: 1511.75, y: 981.75)), "pointer: 1,1 stays inside the last pixel")
    // A viewer showing the 3024x1964 capture 1:1 sends pixel centers; every viewer pixel lands in its own Mac pixel.
    var allInPixel = true
    for px in [0, 1, 1511, 1512, 3022, 3023] {
        let n = (Float(px) + 0.5) / 3024
        let p = PointerMapping.point(x: n, y: 0.5, in: main)
        if Int((p.x * 2).rounded(.down)) != px { allInPixel = false; print("    px \(px) -> \(p.x)") }
    }
    check(allInPixel, "pointer: 1:1 viewer pixels hit the same Mac pixels (incl. the last column)")
    let lastRow = PointerMapping.point(x: 0.5, y: (1963.5 / 1964), in: main)
    check(lastRow.y >= 981.5, "pointer: the bottom pixel row is reachable (Dock autohide, hot corners)")
    // A secondary display left of and above the main one.
    let side = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    check(near(PointerMapping.point(x: 0, y: 0, in: side), CGPoint(x: -1920, y: -200)), "pointer: offset display origin")
    check(PointerMapping.point(x: 1, y: 1, in: side).x < 0, "pointer: right edge stays on that display")
    check(near(PointerMapping.point(x: -3, y: 7, in: main), CGPoint(x: 0, y: 981.75)), "pointer: out-of-range input clamps")
    check(near(PointerMapping.point(x: .nan, y: .infinity, in: main), CGPoint(x: 756, y: 491)), "pointer: NaN/inf -> center")
    // Relative motion.
    check(near(PointerMapping.offset(CGPoint(x: 100, y: 100), dx: 5, dy: -3, in: main), CGPoint(x: 105, y: 97)), "pointer: relative move")
    check(near(PointerMapping.offset(CGPoint(x: 1510, y: 2), dx: 50, dy: -50, in: main), CGPoint(x: 1511.75, y: 0)), "pointer: relative move clamps at the edges")
    var acc = DeltaAccumulator()
    let parts = (0..<4).map { _ in acc.add(dx: 0.5, dy: -0.25) }
    check(parts.map(\.dx).reduce(0, +) == 2 && parts.map(\.dy).reduce(0, +) == -1, "deltas: fractions carried, none lost")
}

private func clickCounterTests() {
    var c = ClickCounter(interval: 0.5, slop: 5)
    let p = CGPoint(x: 100, y: 100)
    check(c.down(button: 0, at: p, time: 10.0) == 1, "clicks: first click")
    check(c.down(button: 0, at: CGPoint(x: 103, y: 98), time: 10.3) == 2, "clicks: double within interval and slop")
    check(c.count(button: 0) == 2, "clicks: up/drag carries the count")
    check(c.down(button: 0, at: p, time: 10.6) == 3, "clicks: triple (interval measured from the previous down)")
    check(c.down(button: 0, at: p, time: 11.2) == 1, "clicks: too slow restarts")
    check(c.down(button: 0, at: CGPoint(x: 110, y: 100), time: 11.3) == 1, "clicks: moved beyond the slop restarts")
    check(c.down(button: 1, at: CGPoint(x: 110, y: 100), time: 11.4) == 1, "clicks: another button restarts")
    check(c.count(button: 0) == 1, "clicks: count for a button that isn't the last one is 1")
    c.reset()
    check(c.down(button: 1, at: p, time: 11.5) == 1, "clicks: reset")
}

private func scrollConverterTests() {
    var s = ScrollConverter()
    // Discrete wheel: 3 lines per notch; horizontal sign flipped for CoreGraphics (wheel2 > 0 = left).
    check(s.scroll(precise: false, dx: 0, dy: 1, now: 0) == [.lines(wheel1: 3, wheel2: 0)], "scroll: one notch up = 3 lines up")
    check(s.scroll(precise: false, dx: 0, dy: -2, now: 0.1) == [.lines(wheel1: -6, wheel2: 0)], "scroll: two notches down")
    check(s.scroll(precise: false, dx: 1, dy: 0, now: 0.2) == [.lines(wheel1: 0, wheel2: -3)], "scroll: dx > 0 (right) -> wheel2 < 0 (the old code scrolled left)")
    // Precise: pixels in a gesture.
    let b = s.scroll(precise: true, dx: 0, dy: 0.1, now: 1.0)  // 4.8 px
    check(b == [.pixels(wheel1: 4, wheel2: 0, phase: .began)], "scroll: precise starts a gesture")
    check(s.scroll(precise: true, dx: 0, dy: 0.1, now: 1.02) == [.pixels(wheel1: 5, wheel2: 0, phase: .changed)], "scroll: remainder carried (4.8 + 4.8 = 9.6 -> 4 + 5)")
    check(s.scroll(precise: true, dx: 0, dy: 0.001, now: 1.04) == [], "scroll: sub-pixel change posts nothing")
    check(s.tick(now: 1.10) == nil, "scroll: gesture still alive before the timeout")
    check(s.tick(now: 1.15) == .pixels(wheel1: 0, wheel2: 0, phase: .ended), "scroll: idle gesture ends")
    check(!s.inGesture && s.tick(now: 2) == nil, "scroll: ended once")
    _ = s.scroll(precise: true, dx: -0.5, dy: 0, now: 3.0)
    check(s.inferPrecise(dx: 0, dy: 1), "scroll: legacy whole notches continue a running gesture")
    let mixed = s.scroll(precise: false, dx: 0, dy: 1, now: 3.01)
    check(mixed == [.pixels(wheel1: 0, wheel2: 0, phase: .ended), .lines(wheel1: 3, wheel2: 0)], "scroll: a wheel notch ends the gesture first")
    check(s.end() == nil, "scroll: end without a gesture is a no-op")
    // Legacy source inference.
    let fresh = ScrollConverter()
    check(!fresh.inferPrecise(dx: 0, dy: 1) && !fresh.inferPrecise(dx: -2, dy: 0), "scroll: whole notches = wheel")
    check(fresh.inferPrecise(dx: 0, dy: 0.0666) && fresh.inferPrecise(dx: 0.125, dy: 0), "scroll: fractional notches = touchpad / hi-res")
    var n = ScrollConverter()
    check(n.scroll(precise: false, dx: .nan, dy: 1, now: 0) == [], "scroll: NaN ignored")
    check(n.scroll(precise: true, dx: 0, dy: 1e30, now: 0).count == 1, "scroll: huge values don't trap")
}

private func keymapTests() {
    // Every usage the viewer can produce for a key a Mac has, maps.
    let needed: [UInt16] = Array(0x04...0x45) + Array(0x46...0x63) + [0x64, 0x65, 0x67] + Array(0x68...0x6F)
        + [0x85, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x90, 0x91] + Array(0xE0...0xE7)
    let missing = needed.filter { HIDKeymap.macKeyCode(forUsage: $0) == nil }
    check(missing.isEmpty, "keymap: complete for the viewer's usages (missing: \(missing.map { String($0, radix: 16) }))")
    // Distinct keys on the Mac side (aliases on purpose: 0x31/0x32 backslash, F13-F15 for PrtSc/ScrLk/Pause,
    // JIS conversion keys, the two keypad commas).
    let aliases: Set<UInt16> = [0x32, 0x46, 0x47, 0x48, 0x88, 0x8A, 0x8B, 0x8C]
    let codes = needed.filter { !aliases.contains($0) }.compactMap { HIDKeymap.macKeyCode(forUsage: $0) }
    check(Set(codes).count == codes.count, "keymap: no two keys collide")
    check(HIDKeymap.macKeyCode(forUsage: 0xE3) == 0x37 && HIDKeymap.macKeyCode(forUsage: 0xE0) == 0x3B, "keymap: GUI -> Command, Ctrl -> Control")
    check(HIDKeymap.macKeyCode(forUsage: 0x58) == 0x4C && HIDKeymap.macKeyCode(forUsage: 0x28) == 0x24, "keymap: keypad Enter vs Return")
    check(HIDKeymap.macKeyCode(forUsage: 0x68) == 0x69 && HIDKeymap.macKeyCode(forUsage: 0x6F) == 0x5A, "keymap: F13, F20")
    // ISO swap.
    check(HIDKeymap.macKeyCode(forUsage: 0x35) == 0x32 && HIDKeymap.macKeyCode(forUsage: 0x64) == 0x0A, "keymap: ANSI grave / non-US backslash")
    check(HIDKeymap.macKeyCode(forUsage: 0x35, iso: true) == 0x0A && HIDKeymap.macKeyCode(forUsage: 0x64, iso: true) == 0x32, "keymap: ISO swaps grave and non-US backslash like macOS")
    check(HIDKeymap.macKeyCode(forUsage: 0x04, iso: true) == 0x00, "keymap: ISO leaves other keys alone")
    // Media keys go out as system keys.
    check(HIDKeymap.systemKey(forKeyboardUsage: 0x80) == .soundUp && HIDKeymap.systemKey(forKeyboardUsage: 0x7F) == .mute, "keymap: keyboard-page volume keys -> system keys")
    check(HIDKeymap.systemKey(forConsumerUsage: 0xCD)?.rawValue == 16 && HIDKeymap.systemKey(forConsumerUsage: 0xB5)?.rawValue == 17
          && HIDKeymap.systemKey(forConsumerUsage: 0xB6)?.rawValue == 18, "keymap: play/next/previous = NX_KEYTYPE 16/17/18")
    check(HIDKeymap.systemKey(forConsumerUsage: 0xB7) == nil && HIDKeymap.systemKey(forKeyboardUsage: 0x04) == nil, "keymap: no system key for Stop / letters")
}
