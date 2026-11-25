import Foundation
import GlideCore

// The Mac viewer's session shortcuts (⌃⌥⇧+key, docs/WINDOWS_HOST.md "Session shortcuts"): chord
// matching on physical modifier flags, layout resolution, and the filter that keeps the chord
// (and the shortcut key) from ever reaching the PC, with and without the modifier remap.

func viewerShortcutTests() {
    let shift = ShortcutChord.shift, ctrl = ShortcutChord.control, opt = ShortcutChord.option, cmd = ShortcutChord.command
    let chord = ctrl | opt | shift
    // Mac virtual key codes.
    let lShift: UInt16 = 0x38, rShift: UInt16 = 0x3C, lCtrl: UInt16 = 0x3B, lOpt: UInt16 = 0x3A, rOpt: UInt16 = 0x3D, lCmd: UInt16 = 0x37
    let kQ: UInt16 = 0x0C, kF: UInt16 = 0x03, kK: UInt16 = 0x28, kD: UInt16 = 0x02, kSpace: UInt16 = 0x31, kA: UInt16 = 0x00, kC: UInt16 = 0x08
    let b = ShortcutBindings.ansi

    // Chord on flags.
    check(ShortcutChord.matches(flags: chord) && ShortcutChord.matches(flags: chord | 0x10000 | 0x800000 | 0x0001 | 0x0020 | 0x0002),
          "shortcuts: ⌃⌥⇧ matches, ignoring Caps Lock, Fn and device bits")
    check(!ShortcutChord.matches(flags: chord | cmd) && !ShortcutChord.matches(flags: ctrl | opt) && !ShortcutChord.matches(flags: cmd | opt | shift)
          && !ShortcutChord.matches(flags: ctrl | shift) && !ShortcutChord.matches(flags: 0),
          "shortcuts: ⌘ added, a modifier missing, or ⌘⌥⇧ (= Ctrl+Alt+Shift on the PC after the remap) is not the chord")
    check(b.match(keyCode: kQ, flags: chord) == .disconnect && b.match(keyCode: kF, flags: chord) == .toggleFullScreen
          && b.match(keyCode: kK, flags: chord) == .releaseKeyboard && b.match(keyCode: kD, flags: chord) == .reconnect
          && b.match(keyCode: kSpace, flags: chord) == .openMenu, "shortcuts: Q F K D Space")
    check(b.match(keyCode: kQ, flags: cmd) == nil && b.match(keyCode: kA, flags: chord) == nil && b.match(keyCode: kF, flags: ctrl | cmd) == nil,
          "shortcuts: ⌘Q, ⌃⌥⇧A and ⌃⌘F are not shortcuts (they go to the PC)")
    check(ShortcutBindings.label(.disconnect) == "⌃⌥⇧Q" && ShortcutBindings.label(.openMenu) == "⌃⌥⇧Space"
          && ShortcutBindings.hint.contains("⌃⌥⇧Q disconnect") && ShortcutBindings.hint.contains("⌃⌥⇧K release keyboard"),
          "shortcuts: labels and the session-start hint")
    check(Set(ViewerShortcut.allCases.map(\.ansiKeyCode)).count == ViewerShortcut.allCases.count, "shortcuts: one key each")

    // Layouts: a character map per key code.
    func layout(_ swaps: [UInt16: String]) -> (UInt16) -> String? {
        let us: [UInt16: String] = [0x00: "a", 0x0C: "q", 0x0D: "w", 0x06: "z", 0x03: "f", 0x28: "k", 0x02: "d", 0x31: " ", 0x2E: "m", 0x29: ";"]
        return { swaps[$0] ?? us[$0] }
    }
    check(ShortcutBindings.resolve(character: layout([:])) == .ansi, "shortcuts: US layout keeps the ANSI keys")
    let azerty = ShortcutBindings.resolve(character: layout([0x00: "q", 0x0C: "a", 0x0D: "z", 0x06: "w", 0x29: "m", 0x2E: ","]))
    check(azerty.match(keyCode: kA, flags: chord) == .disconnect && azerty.match(keyCode: kQ, flags: chord) == nil
          && azerty.match(keyCode: kF, flags: chord) == .toggleFullScreen, "shortcuts: AZERTY, ⌃⌥⇧Q is the key labelled Q (ANSI A position)")
    let cyrillic = ShortcutBindings.resolve(character: { code in String(UnicodeScalar(0x430 + UInt32(code % 32))!) })
    check(cyrillic == .ansi, "shortcuts: a layout without the letters keeps the ANSI positions")
    check(ShortcutBindings.resolve(character: layout([0x00: "q"])) == .ansi, "shortcuts: a letter on two keys keeps the ANSI position")

    // The filter. Each event's output; `sent` maps the sends to HID usages as KeyCapture does.
    func usages(_ out: [ShortcutKeyFilter.Output], remap: Bool) -> [String] {
        out.map {
            switch $0 {
            case let .send(code, down): return String(format: "%@%02X", down ? "+" : "-", MacKeymap.hidUsage(forMacKeyCode: code, remap: remap) ?? 0)
            case let .shortcut(s): return "!\(s.rawValue)"
            }
        }
    }
    func run(_ remap: Bool, _ steps: (inout ShortcutKeyFilter) -> [[ShortcutKeyFilter.Output]]) -> [String] {
        var f = ShortcutKeyFilter()
        return usages(steps(&f).flatMap { $0 }, remap: remap)
    }

    // ⌃⌥⇧Q pressed and released in any order: only the shortcut, nothing reaches the PC.
    for remap in [true, false] {
        let r = run(remap) { f in [
            f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
            f.keyDown(kQ, flags: chord), f.keyDown(kQ, flags: chord),  // auto-repeat
            f.modifier(lShift, down: false), f.keyUp(kQ), f.modifier(lOpt, down: false), f.modifier(lCtrl, down: false),
        ] }
        check(r == ["!disconnect"], "shortcuts: ⌃⌥⇧Q sends nothing to the PC, repeat ignored (remap \(remap)) \(r)")
    }
    // Right-hand modifiers, another press order.
    let right = run(true) { f in [f.modifier(rShift, down: true), f.modifier(rOpt, down: true), f.modifier(0x3E, down: true),
                                  f.keyDown(kF, flags: chord), f.keyUp(kF), f.modifier(0x3E, down: false), f.modifier(rOpt, down: false), f.modifier(rShift, down: false)] }
    check(right == ["!toggleFullScreen"], "shortcuts: right-hand ⇧⌥⌃F \(right)")
    // Holding the chord: two shortcuts in a row.
    let twice = run(true) { f in [f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                  f.keyDown(kF, flags: chord), f.keyUp(kF), f.keyDown(kF, flags: chord), f.keyUp(kF),
                                  f.modifier(lCtrl, down: false), f.modifier(lOpt, down: false), f.modifier(lShift, down: false)] }
    check(twice == ["!toggleFullScreen", "!toggleFullScreen"], "shortcuts: chord held, F twice \(twice)")

    // Not a shortcut: held-back modifiers are sent before the key, in press order.
    let shiftA = run(true) { f in [f.modifier(lShift, down: true), f.keyDown(kA, flags: shift), f.keyUp(kA), f.modifier(lShift, down: false)] }
    check(shiftA == ["+E1", "+04", "-04", "-E1"], "shortcuts: Shift+A reaches the PC unchanged \(shiftA)")
    let ctrlOptShiftA = run(true) { f in [f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                          f.keyDown(kA, flags: chord), f.keyUp(kA), f.modifier(lShift, down: false), f.modifier(lOpt, down: false), f.modifier(lCtrl, down: false)] }
    check(ctrlOptShiftA == ["+E3", "+E2", "+E1", "+04", "-04", "-E1", "-E2", "-E3"],
          "shortcuts: ⌃⌥⇧A (not a shortcut) arrives as Win+Alt+Shift+A with the remap \(ctrlOptShiftA)")
    let noRemap = run(false) { f in [f.modifier(lCtrl, down: true), f.keyDown(kC, flags: ctrl), f.keyUp(kC), f.modifier(lCtrl, down: false)] }
    check(noRemap == ["+E0", "+06", "-06", "-E0"], "shortcuts: remap off, ⌃C is Ctrl+C \(noRemap)")
    // Command is never held back; it releases what was.
    let cmdC = run(true) { f in [f.modifier(lCmd, down: true), f.keyDown(kC, flags: cmd), f.keyUp(kC), f.modifier(lCmd, down: false)] }
    check(cmdC == ["+E0", "+06", "-06", "-E0"], "shortcuts: ⌘C is Ctrl+C at once with the remap \(cmdC)")
    let optCmd = run(true) { f in [f.modifier(lOpt, down: true), f.modifier(lCmd, down: true), f.modifier(lCmd, down: false), f.modifier(lOpt, down: false)] }
    check(optCmd == ["+E2", "+E0", "-E0", "-E2"], "shortcuts: ⌥ then ⌘: ⌥ sent before ⌘ \(optCmd)")
    // ⌘⌥⇧Q (the Windows viewer's chord, Ctrl+Alt+Shift on the PC) is forwarded.
    let cmdChord = run(true) { f in [f.modifier(lCmd, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                     f.keyDown(kQ, flags: cmd | opt | shift), f.keyUp(kQ)] }
    check(cmdChord == ["+E0", "+E2", "+E1", "+14", "-14"], "shortcuts: ⌘⌥⇧Q goes to the PC as Ctrl+Alt+Shift+Q \(cmdChord)")

    // A modifier tapped alone still arrives (Control = Windows: Start menu).
    let tap = run(true) { f in [f.modifier(lCtrl, down: true), f.modifier(lCtrl, down: false)] }
    check(tap == ["+E3", "-E3"], "shortcuts: Control tapped alone sends Win down/up with the remap \(tap)")
    let partial = run(true) { f in [f.modifier(lCtrl, down: true), f.modifier(lShift, down: true), f.modifier(lShift, down: false), f.modifier(lCtrl, down: false)] }
    check(partial == ["+E3", "+E1", "-E1", "-E3"], "shortcuts: ⌃⇧ pressed and released without a key arrive in order \(partial)")
    // Clicks and scrolls flush (Shift-click).
    var f = ShortcutKeyFilter()
    _ = f.modifier(lShift, down: true)
    check(f.heldBack == [lShift] && usages(f.flush(), remap: true) == ["+E1"] && f.heldBack.isEmpty
          && usages(f.modifier(lShift, down: false), remap: true) == ["-E1"], "shortcuts: flush (before a click) sends Shift, its release follows")
    // While a sent key is held, modifiers go straight through; the shortcut still fires.
    let held = run(true) { f in [f.keyDown(kA, flags: 0), f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                 f.keyDown(kQ, flags: chord), f.keyUp(kQ), f.keyUp(kA)] }
    check(held == ["+04", "+E3", "+E2", "+E1", "!disconnect", "-04"], "shortcuts: with a key held, modifiers aren't held back \(held)")
    // After a shortcut, a modifier still down is used up; pressing it again is held back afresh.
    let after = run(true) { f in [f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                  f.keyDown(kK, flags: chord), f.keyUp(kK), f.modifier(lShift, down: false), f.modifier(lShift, down: true),
                                  f.keyDown(kA, flags: chord), f.keyUp(kA), f.modifier(lShift, down: false), f.modifier(lOpt, down: false), f.modifier(lCtrl, down: false)] }
    check(after == ["!releaseKeyboard", "+E1", "+04", "-04", "-E1"], "shortcuts: modifiers used by a shortcut stay off the PC \(after)")
    // Reset forgets everything; unknown releases pass through.
    var g = ShortcutKeyFilter()
    _ = g.modifier(lCtrl, down: true)
    _ = g.keyDown(kQ, flags: chord)
    g.reset()
    check(g.heldBack.isEmpty && usages(g.keyUp(kQ), remap: true) == ["-14"], "shortcuts: reset clears held-back and swallowed keys")
    // Duplicate modifier-down events don't double up.
    let dup = run(true) { f in [f.modifier(lShift, down: true), f.modifier(lShift, down: true), f.keyDown(kA, flags: shift)] }
    check(dup == ["+E1", "+04"], "shortcuts: a repeated modifier down is sent once \(dup)")
    // Mid-drag, a modifier reaches the PC at once (the drag's moves need it), and is released.
    let drag = run(true) { f in [f.pointerButton(1, down: true), f.modifier(lShift, down: true), f.pointerButton(1, down: false), f.modifier(lShift, down: false)] }
    check(drag == ["+E1", "-E1"], "shortcuts: Shift pressed during a drag is sent at once \(drag)")
    // F held before the chord: its repeat fires the shortcut, and F is released on the PC first.
    let heldF = run(true) { f in [f.keyDown(kF, flags: 0), f.modifier(lCtrl, down: true), f.modifier(lOpt, down: true), f.modifier(lShift, down: true),
                                  f.keyDown(kF, flags: chord), f.keyUp(kF)] }
    check(heldF.first == "+09" && heldF.contains("-09") && heldF.contains("!toggleFullScreen")
          && heldF.firstIndex(of: "-09")! < heldF.firstIndex(of: "!toggleFullScreen")! && heldF.filter { $0 == "-09" }.count == 1,
          "shortcuts: a key held before the chord is released on the PC before its shortcut \(heldF)")
}
