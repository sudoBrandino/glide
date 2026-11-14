import AppKit
import CoreGraphics
import GlideCore

/// Injects remote mouse/keyboard input as CGEvents. Call from a single serial queue.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    /// The display being captured (Session sets it on every VideoConfig); nil or offline -> ActiveDisplay.
    private var displayID: CGDirectDisplayID?
    private var heldButtons = Set<UInt8>()
    private var heldKeys = Set<UInt16>()      // mac key codes
    private var flags: CGEventFlags = []
    private var capsOn = false
    private var lastPos = CGPoint.zero
    private var lastClick: (button: UInt8, time: TimeInterval, pos: CGPoint, count: Int64)?
    private var wheelRemainder = CGPoint.zero
    /// Pixels scrolled per wheel notch.
    var pixelsPerNotch: CGFloat = 48

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    func setDisplay(_ id: CGDirectDisplayID) { displayID = id }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let id = displayID.flatMap { ActiveDisplay.isOnline($0) ? $0 : nil } ?? ActiveDisplay.current()
        let b = CGDisplayBounds(id)
        let cx = min(max(CGFloat(x), 0), 1), cy = min(max(CGFloat(y), 0), 1)
        return CGPoint(x: b.minX + cx * (b.width - 1), y: b.minY + cy * (b.height - 1))
    }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.flags = flags.union(e.flags)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    func mouseMove(x: Float, y: Float) {
        let p = point(x, y)
        lastPos = p
        let (type, button): (CGEventType, CGMouseButton)
        if heldButtons.contains(0) { (type, button) = (.leftMouseDragged, .left) }
        else if heldButtons.contains(1) { (type, button) = (.rightMouseDragged, .right) }
        else if let b = heldButtons.first { (type, button) = (.otherMouseDragged, CGMouseButton(rawValue: UInt32(b)) ?? .center) }
        else { (type, button) = (.mouseMoved, .left) }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        post(e)
    }

    func mouseButton(_ button: UInt8, down: Bool) {
        let cgButton: CGMouseButton
        let type: CGEventType
        switch button {
        case 0: cgButton = .left; type = down ? .leftMouseDown : .leftMouseUp
        case 1: cgButton = .right; type = down ? .rightMouseDown : .rightMouseUp
        default:
            cgButton = CGMouseButton(rawValue: button == 2 ? 2 : UInt32(button)) ?? .center
            type = down ? .otherMouseDown : .otherMouseUp
        }
        // Click counting for double/triple click.
        var count: Int64 = 1
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            if let lc = lastClick, lc.button == button, now - lc.time < NSEvent.doubleClickInterval,
               abs(lc.pos.x - lastPos.x) < 5, abs(lc.pos.y - lastPos.y) < 5 {
                count = lc.count + 1
            }
            lastClick = (button, now, lastPos, count)
            heldButtons.insert(button)
        } else {
            count = lastClick?.button == button ? lastClick!.count : 1
            heldButtons.remove(button)
        }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPos, mouseButton: cgButton)
        e?.setIntegerValueField(.mouseEventClickState, value: count)
        if button >= 2 { e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        post(e)
    }

    func wheel(dx: Float, dy: Float) {
        wheelRemainder.x += CGFloat(dx) * pixelsPerNotch
        wheelRemainder.y += CGFloat(dy) * pixelsPerNotch
        let px = Int32(wheelRemainder.x.rounded(.towardZero)), py = Int32(wheelRemainder.y.rounded(.towardZero))
        guard px != 0 || py != 0 else { return }
        wheelRemainder.x -= CGFloat(px); wheelRemainder.y -= CGFloat(py)
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: py, wheel2: px, wheel3: 0)
        post(e)
    }

    // MARK: Keyboard

    private func flag(for m: HIDKeymap.Modifier) -> CGEventFlags {
        switch m {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .capsLock: return .maskAlphaShift
        }
    }

    private func recomputeFlags() {
        var f: CGEventFlags = capsOn ? .maskAlphaShift : []
        for k in heldKeys { if let m = HIDKeymap.modifier(forMacKeyCode: k), m != .capsLock { f.insert(flag(for: m)) } }
        flags = f
    }

    func key(usage: UInt16, down: Bool) {
        guard let code = HIDKeymap.macKeyCode(forUsage: usage) else { return }
        // A down for a key that's already held is the viewer's autorepeat.
        let isRepeat = down && heldKeys.contains(code)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        if let m = HIDKeymap.modifier(forMacKeyCode: code) {
            if isRepeat { return }
            if m == .capsLock { if down { capsOn.toggle() } }
            recomputeFlags()
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.type = .flagsChanged
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            return
        }
        if isRepeat && HIDKeymap.modifier(forMacKeyCode: code) != nil { return }  // modifiers don't repeat
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        if isRepeat { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e?.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        for b in heldButtons { mouseButton(b, down: false) }
        for k in heldKeys {
            heldKeys.remove(k)
            recomputeFlags()
            let e = CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)
            if HIDKeymap.modifier(forMacKeyCode: k) != nil { e?.type = .flagsChanged }
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        heldKeys.removeAll()
        recomputeFlags()
    }
}
