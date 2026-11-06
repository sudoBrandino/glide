//! PC set-1 scancode → USB HID Keyboard/Keypad page (0x07) usage mapping,
//! plus the Windows→Mac modifier remap. Platform independent so it is unit-tested on macOS.
//!
//! Scancodes are expressed as `u16`: the low byte is the make code, and `0xE000`
//! is OR-ed in for E0-prefixed ("extended") keys, matching what Windows reports via
//! `lParam` bits 16–23 + bit 24 or `KBDLLHOOKSTRUCT::scanCode` + `LLKHF_EXTENDED`.

pub const EXT: u16 = 0xE000;

// Modifier usages
pub const HID_LCTRL: u16 = 0xE0;
pub const HID_LSHIFT: u16 = 0xE1;
pub const HID_LALT: u16 = 0xE2;
pub const HID_LGUI: u16 = 0xE3;
pub const HID_RCTRL: u16 = 0xE4;
pub const HID_RSHIFT: u16 = 0xE5;
pub const HID_RALT: u16 = 0xE6;
pub const HID_RGUI: u16 = 0xE7;

pub const HID_PAUSE: u16 = 0x48;
pub const HID_NUMLOCK: u16 = 0x53;
pub const HID_PRINTSCREEN: u16 = 0x46;

/// Map a set-1 scancode (with `EXT` for E0 keys) to a HID usage. Returns `None` for
/// keys we don't forward (e.g. the fake-shift codes E0 2A / E0 36 emitted around nav keys).
pub fn scancode_to_hid(sc: u16) -> Option<u16> {
    let u = match sc {
        // --- main block
        0x01 => 0x29, // Escape
        0x02 => 0x1E, // 1
        0x03 => 0x1F, // 2
        0x04 => 0x20, // 3
        0x05 => 0x21, // 4
        0x06 => 0x22, // 5
        0x07 => 0x23, // 6
        0x08 => 0x24, // 7
        0x09 => 0x25, // 8
        0x0A => 0x26, // 9
        0x0B => 0x27, // 0
        0x0C => 0x2D, // - _
        0x0D => 0x2E, // = +
        0x0E => 0x2A, // Backspace
        0x0F => 0x2B, // Tab
        0x10 => 0x14, // Q
        0x11 => 0x1A, // W
        0x12 => 0x08, // E
        0x13 => 0x15, // R
        0x14 => 0x17, // T
        0x15 => 0x1C, // Y
        0x16 => 0x18, // U
        0x17 => 0x0C, // I
        0x18 => 0x12, // O
        0x19 => 0x13, // P
        0x1A => 0x2F, // [ {
        0x1B => 0x30, // ] }
        0x1C => 0x28, // Enter
        0x1D => HID_LCTRL,
        0x1E => 0x04, // A
        0x1F => 0x16, // S
        0x20 => 0x07, // D
        0x21 => 0x09, // F
        0x22 => 0x0A, // G
        0x23 => 0x0B, // H
        0x24 => 0x0D, // J
        0x25 => 0x0E, // K
        0x26 => 0x0F, // L
        0x27 => 0x33, // ; :
        0x28 => 0x34, // ' "
        0x29 => 0x35, // ` ~  (JIS: Hankaku/Zenkaku)
        0x2A => HID_LSHIFT,
        0x2B => 0x31, // \ |  (ISO: # ~ shares this scancode; macOS treats 0x31/0x32 alike)
        0x2C => 0x1D, // Z
        0x2D => 0x1B, // X
        0x2E => 0x06, // C
        0x2F => 0x19, // V
        0x30 => 0x05, // B
        0x31 => 0x11, // N
        0x32 => 0x10, // M
        0x33 => 0x36, // , <
        0x34 => 0x37, // . >
        0x35 => 0x38, // / ?
        0x36 => HID_RSHIFT,
        0x37 => 0x55, // Keypad *
        0x38 => HID_LALT,
        0x39 => 0x2C, // Space
        0x3A => 0x39, // Caps Lock
        0x3B => 0x3A, // F1
        0x3C => 0x3B, // F2
        0x3D => 0x3C, // F3
        0x3E => 0x3D, // F4
        0x3F => 0x3E, // F5
        0x40 => 0x3F, // F6
        0x41 => 0x40, // F7
        0x42 => 0x41, // F8
        0x43 => 0x42, // F9
        0x44 => 0x43, // F10
        0x45 => HID_NUMLOCK, // Num Lock (Pause is E1 1D 45; disambiguated by the caller via VK)
        0x46 => 0x47, // Scroll Lock
        // --- keypad
        0x47 => 0x5F, // KP 7 / Home
        0x48 => 0x60, // KP 8 / Up
        0x49 => 0x61, // KP 9 / PgUp
        0x4A => 0x56, // KP -
        0x4B => 0x5C, // KP 4 / Left
        0x4C => 0x5D, // KP 5
        0x4D => 0x5E, // KP 6 / Right
        0x4E => 0x57, // KP +
        0x4F => 0x59, // KP 1 / End
        0x50 => 0x5A, // KP 2 / Down
        0x51 => 0x5B, // KP 3 / PgDn
        0x52 => 0x62, // KP 0 / Ins
        0x53 => 0x63, // KP . / Del
        0x54 => HID_PRINTSCREEN, // Alt+PrintScreen (SysRq)
        0x56 => 0x64, // ISO extra key (\ | left of Z) = Non-US backslash
        0x57 => 0x44, // F11
        0x58 => 0x45, // F12
        0x59 => 0x67, // KP = (Mac keyboards)
        0x5C => 0x8C, // International6 (KP , on some JP keyboards)
        // F13–F24
        0x64 => 0x68,
        0x65 => 0x69,
        0x66 => 0x6A,
        0x67 => 0x6B,
        0x68 => 0x6C,
        0x69 => 0x6D,
        0x6A => 0x6E,
        0x6B => 0x6F,
        0x6C => 0x70,
        0x6D => 0x71,
        0x6E => 0x72,
        0x76 => 0x73, // F24
        // JIS / Korean / Brazilian extras
        0x70 => 0x88, // Katakana/Hiragana  (International2)
        0x73 => 0x87, // Ro / _ \           (International1)
        0x79 => 0x8A, // Henkan (Convert)   (International4)
        0x7B => 0x8B, // Muhenkan           (International5)
        0x7D => 0x89, // Yen                (International3)
        0x7E => 0x85, // Keypad , (Brazil)
        0x71 | 0xF1 => 0x91, // Hanja  (LANG2)
        0x72 | 0xF2 => 0x90, // Hangul (LANG1)

        // --- E0-prefixed
        0xE01C => 0x58, // Keypad Enter
        0xE01D => HID_RCTRL,
        0xE020 => 0x7F, // Mute
        0xE02E => 0x81, // Volume Down
        0xE030 => 0x80, // Volume Up
        0xE035 => 0x54, // Keypad /
        0xE037 => HID_PRINTSCREEN,
        0xE038 => HID_RALT, // Right Alt / AltGr
        0xE045 => HID_NUMLOCK, // Num Lock as reported by Windows (extended flag set)
        0xE046 => HID_PAUSE, // Ctrl+Pause (Break)
        0xE047 => 0x4A, // Home
        0xE048 => 0x52, // Up
        0xE049 => 0x4B, // Page Up
        0xE04B => 0x50, // Left
        0xE04D => 0x4F, // Right
        0xE04F => 0x4D, // End
        0xE050 => 0x51, // Down
        0xE051 => 0x4E, // Page Down
        0xE052 => 0x49, // Insert
        0xE053 => 0x4C, // Delete
        0xE05B => HID_LGUI, // Left Windows
        0xE05C => HID_RGUI, // Right Windows
        0xE05D => 0x65, // Application / Menu
        0xE05E => 0x66, // Power
        0xE036 => HID_RSHIFT, // some drivers flag RShift as extended
        // Fake shifts (E0 2A / E0 AA) around nav keys with NumLock on: drop.
        0xE02A => return None,
        _ => return None,
    };
    Some(u)
}

/// Windows Ctrl → Mac Command, Windows Win → Mac Control. Alt stays Alt (= Option).
pub fn remap_ctrl_as_cmd(usage: u16) -> u16 {
    match usage {
        HID_LCTRL => HID_LGUI,
        HID_RCTRL => HID_RGUI,
        HID_LGUI => HID_LCTRL,
        HID_RGUI => HID_RCTRL,
        u => u,
    }
}

/// Full client-side translation: scancode → HID, with optional modifier remap.
pub fn translate(sc: u16, ctrl_as_cmd: bool) -> Option<u16> {
    let u = scancode_to_hid(sc)?;
    Some(if ctrl_as_cmd { remap_ctrl_as_cmd(u) } else { u })
}

/// Build the `u16` scancode from a WM_KEYDOWN-style lParam.
pub fn scancode_from_lparam(lparam: isize) -> u16 {
    let sc = ((lparam >> 16) & 0xFF) as u16;
    let ext = (lparam >> 24) & 1 != 0;
    if ext { sc | EXT } else { sc }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_digits_function_keys() {
        // QWERTY rows map to the expected letters
        let row = [(0x10, 'q'), (0x1E, 'a'), (0x2C, 'z'), (0x32, 'm'), (0x26, 'l'), (0x19, 'p')];
        for (sc, ch) in row {
            assert_eq!(scancode_to_hid(sc), Some(0x04 + (ch as u16 - 'a' as u16)), "{ch}");
        }
        // All 26 letters present and distinct
        let mut letters: Vec<u16> = (0..=0x7Fu16).filter_map(scancode_to_hid).filter(|u| (0x04..=0x1D).contains(u)).collect();
        letters.sort();
        letters.dedup();
        assert_eq!(letters.len(), 26);
        for (i, sc) in (0x02..=0x0B).enumerate() {
            assert_eq!(scancode_to_hid(sc), Some(0x1E + i as u16));
        }
        for (i, sc) in (0x3B..=0x44).enumerate() {
            assert_eq!(scancode_to_hid(sc), Some(0x3A + i as u16), "F{}", i + 1);
        }
        assert_eq!(scancode_to_hid(0x57), Some(0x44));
        assert_eq!(scancode_to_hid(0x58), Some(0x45));
        for (i, sc) in (0x64..=0x6E).enumerate() {
            assert_eq!(scancode_to_hid(sc), Some(0x68 + i as u16), "F{}", 13 + i);
        }
        assert_eq!(scancode_to_hid(0x76), Some(0x73));
    }

    #[test]
    fn nav_numpad_and_specials() {
        assert_eq!(scancode_to_hid(0xE048), Some(0x52)); // Up
        assert_eq!(scancode_to_hid(0x48), Some(0x60)); // KP8
        assert_eq!(scancode_to_hid(0xE01C), Some(0x58)); // KP Enter
        assert_eq!(scancode_to_hid(0x1C), Some(0x28)); // Enter
        assert_eq!(scancode_to_hid(0xE035), Some(0x54)); // KP /
        assert_eq!(scancode_to_hid(0x45), Some(0x53)); // NumLock
        assert_eq!(scancode_to_hid(0xE045), Some(0x53));
        assert_eq!(scancode_to_hid(0xE037), Some(0x46)); // PrintScreen
        assert_eq!(scancode_to_hid(0xE053), Some(0x4C)); // Delete
        assert_eq!(scancode_to_hid(0x56), Some(0x64)); // ISO
        assert_eq!(scancode_to_hid(0x7D), Some(0x89)); // Yen
        assert_eq!(scancode_to_hid(0xE02A), None); // fake shift
        assert_eq!(scancode_to_hid(0x1D), Some(HID_LCTRL));
        assert_eq!(scancode_to_hid(0xE01D), Some(HID_RCTRL));
        assert_eq!(scancode_to_hid(0xE038), Some(HID_RALT));
        assert_eq!(scancode_to_hid(0xE05B), Some(HID_LGUI));
    }

    #[test]
    fn modifier_remap() {
        assert_eq!(translate(0x1D, true), Some(HID_LGUI)); // LCtrl -> Cmd
        assert_eq!(translate(0xE01D, true), Some(HID_RGUI));
        assert_eq!(translate(0xE05B, true), Some(HID_LCTRL)); // LWin -> Control
        assert_eq!(translate(0xE05C, true), Some(HID_RCTRL));
        assert_eq!(translate(0x38, true), Some(HID_LALT)); // Alt stays
        assert_eq!(translate(0x1D, false), Some(HID_LCTRL));
        assert_eq!(translate(0x1E, true), Some(0x04));
    }

    #[test]
    fn lparam_parsing() {
        // WM_KEYDOWN for Right arrow: scancode 0x4D, extended bit 24 set
        let lp: isize = (0x4D << 16) | (1 << 24) | 1;
        assert_eq!(scancode_from_lparam(lp), 0xE04D);
        assert_eq!(scancode_to_hid(scancode_from_lparam(lp)), Some(0x4F));
        let lp: isize = (0x1E << 16) | 1;
        assert_eq!(scancode_from_lparam(lp), 0x1E);
    }
}
