import AppKit
import Carbon
import CoreGraphics
import GlideCore

/// Injects remote mouse/keyboard input as CGEvents. Every method must run on `queue`.
final class InputInjector {
    /// The serial queue all input runs on (Session dispatches onto it; the scroll-gesture timer
    /// fires on it too).
    let queue = DispatchQueue(label: "glide.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    /// The display being captured (Session sets it on every VideoConfig); nil or offline -> ActiveDisplay.
    private var displayID: CGDirectDisplayID?
    private var heldButtons = Set<UInt8>()
    private var heldKeys = Set<UInt16>()      // mac key codes
    private var heldSystemKeys = Set<Int32>()  // NX key types (media keys)
    private var flags: CGEventFlags = []
    private var capsOn = false
    /// The viewer sends its Caps Lock state (§3.5 LockState): Caps Lock follows it, not key presses.
    private var locksFromViewer = false
    /// Where the last injected event put the pointer (nil: ask the window server).
    private var lastPos: CGPoint?
    private var clicks = ClickCounter(interval: NSEvent.doubleClickInterval)
    private var deltas = DeltaAccumulator()
    private var scroller = ScrollConverter()
    private var scrollTimer: DispatchSourceTimer?
    /// GLIDE_KEYBOARD_TYPE=ansi|iso|jis: present injected keys as that keyboard type instead of
    /// the Mac's current one (decides the ISO key swap, see HIDKeymap).
    private let iso: Bool?

    init() {
        source?.localEventsSuppressionInterval = 0
        switch ProcessInfo.processInfo.environment["GLIDE_KEYBOARD_TYPE"]?.lowercased() {
        case "ansi": source?.keyboardType = 40; iso = false
        case "iso": source?.keyboardType = 41; iso = true
        case "jis": source?.keyboardType = 42; iso = false
        default: iso = nil
        }
    }

    func setDisplay(_ id: CGDirectDisplayID) { displayID = id }

    private var bounds: CGRect {
        let id = displayID.flatMap { ActiveDisplay.isOnline($0) ? $0 : nil } ?? ActiveDisplay.current()
        return CGDisplayBounds(id)
    }

    private var currentPos: CGPoint {
        if let p = lastPos { return p }
        return CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.flags = flags.union(e.flags)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    func mouseMove(x: Float, y: Float) {
        let p = PointerMapping.point(x: x, y: y, in: bounds)
        let from = currentPos
        movePointer(to: p, dx: Double(p.x - from.x), dy: Double(p.y - from.y))
    }

    /// §3.5 relative motion (pointer-lock mode): the pointer moves by the raw counts (clamped to the
    /// display) while the event's delta carries the full motion, so games keep turning at the edge.
    func mouseDelta(dx: Int16, dy: Int16) {
        let p = PointerMapping.offset(currentPos, dx: CGFloat(dx), dy: CGFloat(dy), in: bounds)
        movePointer(to: p, dx: Double(dx), dy: Double(dy))
    }

    private func movePointer(to p: CGPoint, dx: Double, dy: Double) {
        lastPos = p
        let type: CGEventType, button: CGMouseButton, held: UInt8?
        if heldButtons.contains(0) { (type, button, held) = (.leftMouseDragged, .left, 0) }
        else if heldButtons.contains(1) { (type, button, held) = (.rightMouseDragged, .right, 1) }
        else if let b = heldButtons.min() { (type, button, held) = (.otherMouseDragged, Self.cgButton(b), b) }
        else { (type, button, held) = (.mouseMoved, .left, nil) }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        // Synthesized events carry no delta unless we set it; apps that read deltas (3D views,
        // games, some sliders) otherwise see the pointer jump without moving.
        let d = deltas.add(dx: dx, dy: dy)
        e.setIntegerValueField(.mouseEventDeltaX, value: d.dx)
        e.setIntegerValueField(.mouseEventDeltaY, value: d.dy)
        if let b = held {
            e.setIntegerValueField(.mouseEventClickState, value: clicks.count(button: b))
            if b >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        }
        post(e)
    }

    private static func cgButton(_ b: UInt8) -> CGMouseButton {
        CGMouseButton(rawValue: UInt32(b)) ?? .center  // 3 back / 4 forward: .center + button number
    }

    func mouseButton(_ button: UInt8, down: Bool) {
        let cgButton: CGMouseButton
        let type: CGEventType
        switch button {
        case 0: cgButton = .left; type = down ? .leftMouseDown : .leftMouseUp
        case 1: cgButton = .right; type = down ? .rightMouseDown : .rightMouseUp
        default: cgButton = Self.cgButton(button); type = down ? .otherMouseDown : .otherMouseUp
        }
        if !down && !heldButtons.contains(button) { return }  // up without a down (e.g. after ReleaseAll)
        let pos = currentPos
        let count: Int64
        if down {
            clicks.interval = NSEvent.doubleClickInterval
            count = clicks.down(button: button, at: pos, time: ProcessInfo.processInfo.systemUptime)
            heldButtons.insert(button)
        } else {
            count = clicks.count(button: button)
            heldButtons.remove(button)
        }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton)
        e?.setIntegerValueField(.mouseEventClickState, value: count)
        if button >= 2 { e?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        post(e)
    }

    /// Legacy MouseWheel (0x12): the source is inferred from the deltas.
    func wheel(dx: Float, dy: Float) {
        scroll(precise: scroller.inferPrecise(dx: dx, dy: dy), dx: dx, dy: dy)
    }

    /// §3.5 Scroll.
    func scroll(precise: Bool, dx: Float, dy: Float) {
        for o in scroller.scroll(precise: precise, dx: dx, dy: dy, now: ProcessInfo.processInfo.systemUptime) { postScroll(o) }
        if scroller.inGesture { armScrollTimer() }
    }

    private func armScrollTimer() {
        guard scrollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + scroller.gestureTimeout / 2, repeating: scroller.gestureTimeout / 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if let o = self.scroller.tick(now: ProcessInfo.processInfo.systemUptime) { self.postScroll(o) }
            if !self.scroller.inGesture { self.scrollTimer?.cancel(); self.scrollTimer = nil }
        }
        scrollTimer = t
        t.resume()
    }

    private func endScrollGesture() {
        if let o = scroller.end() { postScroll(o) }
        scrollTimer?.cancel()
        scrollTimer = nil
    }

    private func postScroll(_ o: ScrollConverter.Output) {
        switch o {
        case let .lines(w1, w2):
            post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0))
        case let .pixels(w1, w2, phase):
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0)
            e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
            e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
            post(e)
        }
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

    private var isISO: Bool {
        if let iso { return iso }
        let type = source?.keyboardType ?? UInt32(LMGetKbdType())
        return KBGetLayoutType(Int16(truncatingIfNeeded: type)) == OSType(kKeyboardISO)
    }

    func key(usage: UInt16, down: Bool) {
        if let sys = HIDKeymap.systemKey(forKeyboardUsage: usage) { systemKey(sys, down: down); return }
        guard let code = HIDKeymap.macKeyCode(forUsage: usage, iso: isISO) else { return }
        // A down for a key that's already held is the viewer's autorepeat. The Mac doesn't repeat
        // injected keys itself, so the viewer's typematic repeat is the only one.
        let isRepeat = down && heldKeys.contains(code)
        if !down && !heldKeys.contains(code) { return }  // up without a down (e.g. after ReleaseAll)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        if let m = HIDKeymap.modifier(forMacKeyCode: code) {
            if isRepeat { return }  // modifiers don't repeat
            if m == .capsLock, down, !locksFromViewer { capsOn.toggle() }
            recomputeFlags()
            postFlagsChanged(code)
            return
        }
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        if isRepeat { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e?.post(tap: .cghidEventTap)
    }

    private func postFlagsChanged(_ code: UInt16) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        e?.type = .flagsChanged
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    /// §3.5 KeyExtra.
    func keyExtra(_ k: KeyExtra) {
        switch k {
        case let .lockState(l):
            locksFromViewer = true
            let on = l & KeyExtra.capsLock != 0
            guard on != capsOn else { return }
            capsOn = on
            recomputeFlags()
            postFlagsChanged(0x39)  // kVK_CapsLock
        case let .consumerKey(usage, down):
            if let sys = HIDKeymap.systemKey(forConsumerUsage: usage) { systemKey(sys, down: down) }
        case .unknown:
            break
        }
    }

    /// Media keys as system-defined events (what the Mac's own keyboard produces for them).
    private func systemKey(_ k: HIDKeymap.SystemKey, down: Bool) {
        let isRepeat = down && heldSystemKeys.contains(k.rawValue)
        if !down && !heldSystemKeys.contains(k.rawValue) { return }
        if down { heldSystemKeys.insert(k.rawValue) } else { heldSystemKeys.remove(k.rawValue) }
        let state = down ? 0xA : 0xB
        let data1 = (Int(k.rawValue) << 16) | (state << 8) | (isRepeat ? 1 : 0)
        let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                    subtype: 8, data1: data1, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }

    func releaseAll() {
        endScrollGesture()
        for b in heldButtons { mouseButton(b, down: false) }
        for k in heldSystemKeys { if let s = HIDKeymap.SystemKey(rawValue: k) { systemKey(s, down: false) } }
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
