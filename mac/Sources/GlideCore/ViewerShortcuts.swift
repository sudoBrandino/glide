import Foundation

// The Mac viewer's escape shortcuts (docs/WINDOWS_HOST.md "Session shortcuts"): Control+Option+
// Shift+key on the PHYSICAL Mac modifiers, whatever the modifier remap. They are matched before
// anything is forwarded and never reach the PC.
//
// Why ⌃⌥⇧: it mirrors the Windows viewer's Ctrl+Alt+Shift hotkeys, macOS binds nothing to it by
// default, and on the PC it would have arrived as Windows+Alt+Shift (remap on), which Windows
// doesn't use, or Ctrl+Alt+Shift (remap off), the chord the Windows viewer already reserves.
// ⌘⌥⇧ was the alternative: with the remap it arrives as Ctrl+Alt+Shift, which Windows apps (IDEs
// in particular) do bind, and it would shadow Mac habits less predictably.

/// One escape shortcut. Letters follow the Windows viewer where it has the same action
/// (F full screen, K keyboard, D reconnect, Space menu); Q disconnects, like ⌘Q quits.
public enum ViewerShortcut: String, CaseIterable, Sendable {
    case disconnect, toggleFullScreen, releaseKeyboard, reconnect, openMenu

    /// The character the key types on the current layout (menus show it; see `ShortcutBindings`).
    public var character: String {
        switch self {
        case .disconnect: return "q"
        case .toggleFullScreen: return "f"
        case .releaseKeyboard: return "k"
        case .reconnect: return "d"
        case .openMenu: return " "
        }
    }

    /// The key's position on an ANSI (US) layout: kVK_ANSI_Q, _F, _K, _D, kVK_Space.
    public var ansiKeyCode: UInt16 {
        switch self {
        case .disconnect: return 0x0C
        case .toggleFullScreen: return 0x03
        case .releaseKeyboard: return 0x28
        case .reconnect: return 0x02
        case .openMenu: return 0x31
        }
    }

    public var title: String {
        switch self {
        case .disconnect: return "Disconnect"
        case .toggleFullScreen: return "Full screen"
        case .releaseKeyboard: return "Release keyboard"
        case .reconnect: return "Reconnect"
        case .openMenu: return "Session menu"
        }
    }

    /// One line for Settings and the docs.
    public var help: String {
        switch self {
        case .disconnect: return "End the session and go back to your connections"
        case .toggleFullScreen: return "Enter or leave full screen"
        case .releaseKeyboard: return "Stop sending keys to the PC (⌘Tab etc. work on the Mac) until you click the session"
        case .reconnect: return "Drop the connection and dial again"
        case .openMenu: return "Open the session menu at the pointer"
        }
    }
}

/// The reserved modifier chord, on NSEvent.ModifierFlags / CGEventFlags device-independent bits
/// (the two share them).
public enum ShortcutChord {
    public static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000
    static let considered = shift | control | option | command
    static let required = shift | control | option
    /// Menu glyphs, in Apple's order.
    public static let symbol = "⌃⌥⇧"

    /// Exactly Control, Option and Shift (either side) are down; Command is not. Caps Lock, Fn
    /// (set on arrow and function keys) and the device bits are ignored.
    public static func matches(flags: UInt64) -> Bool { flags & considered == required }

    /// Modifier keys that make up the chord (the ones `ShortcutKeyFilter` holds back).
    public static func isChordModifier(keyCode: UInt16) -> Bool {
        switch HIDKeymap.modifier(forMacKeyCode: keyCode) {
        case .shift?, .control?, .option?: return true
        default: return false
        }
    }
}

/// Which physical key (Mac virtual key code) triggers each shortcut on this Mac's keyboard
/// layout. Menus match key equivalents by character, so on AZERTY ⌃⌥⇧Q is the key labelled Q
/// (kVK_ANSI_A's position): `resolve` finds that key so the menu label and the captured key agree.
public struct ShortcutBindings: Equatable, Sendable {
    public private(set) var keyCodes: [ViewerShortcut: UInt16]

    /// Positions on a US layout.
    public static let ansi = ShortcutBindings(keyCodes: Dictionary(uniqueKeysWithValues: ViewerShortcut.allCases.map { ($0, $0.ansiKeyCode) }))

    /// `character(code)`: what the key types on the current layout without modifiers (lowercase),
    /// nil if unknown. A letter missing from the layout (Cyrillic, Greek, …) keeps its ANSI
    /// position, like AppKit's own fallback for key equivalents on non-Latin layouts.
    public static func resolve(character: (UInt16) -> String?) -> ShortcutBindings {
        var codes = ansi.keyCodes
        var used = Set<UInt16>()
        let candidates = MacKeymap.mappedKeyCodes.filter { HIDKeymap.modifier(forMacKeyCode: $0) == nil }
        for s in ViewerShortcut.allCases where s != .openMenu {
            if character(s.ansiKeyCode)?.lowercased() == s.character, !used.contains(s.ansiKeyCode) {
                used.insert(s.ansiKeyCode)
                continue
            }
            if let c = candidates.first(where: { !used.contains($0) && character($0)?.lowercased() == s.character }) {
                codes[s] = c
                used.insert(c)
            } else {
                used.insert(s.ansiKeyCode)
            }
        }
        // Two shortcuts on one key (a layout with a letter twice and another missing): keep ANSI.
        if Set(codes.values).count != codes.count { return ansi }
        return ShortcutBindings(keyCodes: codes)
    }

    /// The shortcut for a key-down of `keyCode` with these flags, if it is one.
    public func match(keyCode: UInt16, flags: UInt64) -> ViewerShortcut? {
        guard ShortcutChord.matches(flags: flags) else { return nil }
        return keyCodes.first { $0.value == keyCode }?.key
    }

    /// "⌃⌥⇧Q", "⌃⌥⇧Space".
    public static func label(_ s: ViewerShortcut) -> String {
        ShortcutChord.symbol + (s == .openMenu ? "Space" : s.character.uppercased())
    }

    /// The toast shown when a session starts streaming or enters full screen.
    public static var hint: String {
        "\(label(.disconnect)) disconnect · \(label(.toggleFullScreen)) full screen · \(label(.releaseKeyboard)) release keyboard · \(label(.openMenu)) menu"
    }
}

/// Sits between the captured key events and the PC, so the PC never sees the chord: the
/// Control, Option and Shift presses that could start one are held back until something shows
/// they are not a shortcut (another key, a click or scroll, Command, or a release), then sent in
/// the order they were pressed. A modifier tapped on its own still arrives (down, then up, on
/// release), so tapping Control (Windows with the remap) still opens Start.
///
/// Holding back only starts from a clean state: while any key that was sent is still down,
/// modifiers go straight through (the shortcut still fires; the PC then sees those modifiers).
///
/// Works on Mac virtual key codes; the caller maps them to HID usages (remap, ISO).
public struct ShortcutKeyFilter {
    public enum Output: Equatable, Sendable {
        case send(keyCode: UInt16, down: Bool)
        case shortcut(ViewerShortcut)
    }

    public var bindings: ShortcutBindings
    /// Chord modifiers pressed but not sent yet, in press order.
    public private(set) var heldBack: [UInt16] = []
    /// Keys sent down and not released yet.
    private var forwarded = Set<UInt16>()
    /// Keys whose remaining events are dropped: shortcut keys (their repeats and release), and
    /// held-back modifiers a shortcut used up (their release).
    private var swallowed = Set<UInt16>()
    /// Mouse buttons down in the session: while one is (a drag), modifiers go straight through,
    /// since the drag's moves would otherwise reach the PC without them (Shift to constrain).
    private var buttons = Set<UInt8>()

    public init(bindings: ShortcutBindings = .ansi) { self.bindings = bindings }

    /// A non-modifier key went down (`flags`: the event's modifier flags).
    public mutating func keyDown(_ code: UInt16, flags: UInt64) -> [Output] {
        if swallowed.contains(code) { return [] }  // auto-repeat of a shortcut key
        if let s = bindings.match(keyCode: code, flags: flags) {
            // The key was already down on the PC (held before the chord, now repeating): release
            // it there before its remaining events are swallowed, or it would stay held.
            var out: [Output] = []
            if forwarded.remove(code) != nil { out.append(.send(keyCode: code, down: false)) }
            swallowed.insert(code)
            swallowed.formUnion(heldBack)
            heldBack.removeAll()
            out.append(.shortcut(s))
            return out
        }
        var out = flush()
        forwarded.insert(code)
        out.append(.send(keyCode: code, down: true))
        return out
    }

    public mutating func keyUp(_ code: UInt16) -> [Output] {
        if swallowed.remove(code) != nil { return [] }
        forwarded.remove(code)
        return [.send(keyCode: code, down: false)]
    }

    /// A modifier key (Shift, Control, Option, Command) went down or up.
    public mutating func modifier(_ code: UInt16, down: Bool) -> [Output] {
        if down {
            if heldBack.contains(code) || forwarded.contains(code) { return [] }  // duplicate event
            swallowed.remove(code)
            if ShortcutChord.isChordModifier(keyCode: code) && forwarded.isEmpty && buttons.isEmpty {
                heldBack.append(code)
                return []
            }
            var out = flush()
            forwarded.insert(code)
            out.append(.send(keyCode: code, down: true))
            return out
        }
        if swallowed.remove(code) != nil { return [] }
        if heldBack.contains(code) {
            var out = flush()
            forwarded.remove(code)
            out.append(.send(keyCode: code, down: false))
            return out
        }
        forwarded.remove(code)
        return [.send(keyCode: code, down: false)]
    }

    /// Sends the held-back modifiers now: before a mouse button, a scroll, Caps Lock, or anything
    /// else the modifiers should apply to.
    public mutating func flush() -> [Output] {
        guard !heldBack.isEmpty else { return [] }
        let out = heldBack.map { Output.send(keyCode: $0, down: true) }
        forwarded.formUnion(heldBack)
        heldBack.removeAll()
        return out
    }

    /// A mouse button went down or up in the session. Sends the held-back modifiers first (they
    /// apply to the click: Shift-click, Ctrl-click).
    public mutating func pointerButton(_ button: UInt8, down: Bool) -> [Output] {
        if down { buttons.insert(button) } else { buttons.remove(button) }
        return flush()
    }

    /// Forget everything (capture stopped; the PC was told to release all keys).
    public mutating func reset() {
        buttons.removeAll()
        heldBack.removeAll()
        forwarded.removeAll()
        swallowed.removeAll()
    }
}
