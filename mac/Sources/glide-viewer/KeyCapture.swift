import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import GlideCore

/// Where captured keys go (main thread).
protocol KeySink: AnyObject {
    /// True while keys should go to the host (streaming, and the viewer window is key).
    var capturingKeys: Bool { get }
    func sendKey(usage: UInt16, down: Bool)
    /// A session shortcut (⌃⌥⇧+key) was pressed while capturing. Called from inside the event
    /// tap or the local monitor: defer anything that tears down windows or the capture.
    func shortcut(_ s: ViewerShortcut)
}

/// Keyboard capture while the viewer window is focused: NSEvent key events through a local
/// monitor (before menus see them), and, with Accessibility permission, a CGEventTap that also
/// takes system shortcuts (⌘Tab, ⌘Space, …) before macOS acts on them. Without the permission
/// those shortcuts stay with this Mac.
///
/// Both paths go through `ShortcutKeyFilter`: the session shortcuts (⌃⌥⇧Q, F, K, D, Space) are
/// taken here and never reach the PC, and the Control/Option/Shift presses that make them up are
/// held back until they turn out not to be one.
final class KeyCapture {
    weak var sink: KeySink?
    var remap: Bool
    private var monitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var filter = ShortcutKeyFilter()
    private var layoutObserver: NSObjectProtocol?

    init(remap: Bool) { self.remap = remap }

    deinit { stop() }

    /// The current shortcut keys for this keyboard layout (menus use the same characters).
    static func currentBindings() -> ShortcutBindings {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return .ansi }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let kbType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { raw -> ShortcutBindings in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return .ansi }
            return ShortcutBindings.resolve { code in
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var n = 0
                let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, kbType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &n, &chars)
                guard st == noErr, n > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: n)
            }
        }
    }

    func start() {
        filter.bindings = KeyCapture.currentBindings()
        if layoutObserver == nil {
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                self?.filter.bindings = KeyCapture.currentBindings()
            }
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
                guard let self else { return e }
                return self.handle(e) ? nil : e
            }
        }
        startTap()
    }

    func stop() {
        if let o = layoutObserver { DistributedNotificationCenter.default().removeObserver(o); layoutObserver = nil }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Installs the event tap if this process is trusted for Accessibility.
    private func startTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            print("Accessibility permission not granted: system shortcuts (⌘Tab, ⌘Space, …) stay with this Mac. "
                + "Grant it in System Settings → Privacy & Security → Accessibility to send them to the PC.")
            return
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: me) else {
            print("could not install the keyboard event tap; system shortcuts stay with this Mac")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        tapSource = src
        print("keyboard event tap installed: system shortcuts go to the PC while the viewer is focused")
    }

    private var isISO: Bool {
        KBGetLayoutType(Int16(truncatingIfNeeded: UInt32(LMGetKbdType()))) == OSType(kKeyboardISO)
    }

    /// Capture stopped or the PC was told to release everything: forget held and held-back keys.
    func reset() { filter.reset() }

    /// Sends the held-back Control/Option/Shift presses before a click or scroll they apply to.
    func flushModifiers() { deliver(filter.flush()) }

    /// A click in the session: sends held-back modifiers first, and tracks drags (modifiers
    /// pressed during one go straight through).
    func mouseButton(_ button: UInt8, down: Bool) { deliver(filter.pointerButton(button, down: down)) }

    /// One key event. Returns true when it was consumed here (sent to the host, or a shortcut).
    func handleKey(code: UInt16, type: CGEventType, flags: UInt64) -> Bool {
        guard let sink else { return false }
        guard sink.capturingKeys else {
            // Whatever was held back or swallowed is moot once keys stay on this Mac.
            filter.reset()
            return false
        }
        switch type {
        case .keyDown:
            deliver(filter.keyDown(code, flags: flags))
            return true
        case .keyUp:
            deliver(filter.keyUp(code))
            return true
        case .flagsChanged:
            if code == MacKeymap.capsLockKeyCode {
                // macOS reports Caps Lock once per press (lock state): press + release toggles it on the PC too.
                deliver(filter.flush())
                sink.sendKey(usage: 0x39, down: true)
                sink.sendKey(usage: 0x39, down: false)
                return true
            }
            guard let down = MacKeymap.modifierIsDown(keyCode: code, flags: flags) else { return true }
            deliver(filter.modifier(code, down: down))
            return true
        default:
            return false
        }
    }

    private func deliver(_ out: [ShortcutKeyFilter.Output]) {
        guard let sink else { return }
        for o in out {
            switch o {
            case let .send(code, down):
                // Modifiers have no ISO variant.
                let iso = HIDKeymap.modifier(forMacKeyCode: code) == nil && isISO
                if let u = MacKeymap.hidUsage(forMacKeyCode: code, iso: iso, remap: remap) { sink.sendKey(usage: u, down: down) }
            case let .shortcut(s):
                sink.shortcut(s)
            }
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let type: CGEventType
        switch e.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        default: return false
        }
        return handleKey(code: e.keyCode, type: type, flags: UInt64(e.modifierFlags.rawValue))
    }

    /// From the tap callback (main run loop).
    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        return handleKey(code: code, type: type, flags: event.flags.rawValue)
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<KeyCapture>.fromOpaque(refcon).takeUnretainedValue()
    return capture.handleTap(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
