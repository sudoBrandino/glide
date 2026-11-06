//! Viewer-local hotkeys. They are matched on *physical* keys (HID usages before the
//! Ctrl→Cmd remap) and never forwarded to the host.
//!
//! All letter hotkeys use Ctrl+Alt+Shift (= Cmd+Option+Shift on the Mac side after the remap),
//! a combination macOS apps essentially never bind, so they don't shadow Mac shortcuts.

use crate::hid::{HID_LALT, HID_LCTRL, HID_LGUI, HID_LSHIFT, HID_RALT, HID_RCTRL, HID_RGUI, HID_RSHIFT};
use crate::protocol::Mode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Action {
    ToggleHud = 1,
    CycleMode = 2,
    ToggleFullscreen = 3,
    ToggleKeyboardCapture = 4,
    RequestKeyframe = 5,
    Reconnect = 6,
}

impl Action {
    pub fn from_u8(v: u8) -> Option<Action> {
        Some(match v {
            1 => Action::ToggleHud,
            2 => Action::CycleMode,
            3 => Action::ToggleFullscreen,
            4 => Action::ToggleKeyboardCapture,
            5 => Action::RequestKeyframe,
            6 => Action::Reconnect,
            _ => return None,
        })
    }
    /// Name used by the `GLIDE_TEST_ACTIONS` test hook.
    pub fn from_name(s: &str) -> Option<Action> {
        Some(match s.trim().to_ascii_lowercase().as_str() {
            "hud" | "h" => Action::ToggleHud,
            "mode" | "m" => Action::CycleMode,
            "fullscreen" | "f" => Action::ToggleFullscreen,
            "keyboard" | "k" => Action::ToggleKeyboardCapture,
            "keyframe" | "r" => Action::RequestKeyframe,
            "reconnect" | "d" => Action::Reconnect,
            _ => return None,
        })
    }
}

/// HID usages of the hotkey letters.
pub const KEY_D: u16 = 0x07;
pub const KEY_F: u16 = 0x09;
pub const KEY_H: u16 = 0x0B;
pub const KEY_K: u16 = 0x0E;
pub const KEY_M: u16 = 0x10;
pub const KEY_R: u16 = 0x15;
pub const KEY_ENTER: u16 = 0x28;
pub const KEY_F11: u16 = 0x44;

/// Hotkey table: (letter usage, action, description) — all with Ctrl+Alt+Shift.
pub const TABLE: &[(u16, Action, &str)] = &[
    (KEY_H, Action::ToggleHud, "Ctrl+Alt+Shift+H  toggle the stats overlay"),
    (KEY_M, Action::CycleMode, "Ctrl+Alt+Shift+M  cycle stream mode fast → hybrid → sharp"),
    (KEY_F, Action::ToggleFullscreen, "Ctrl+Alt+Shift+F  toggle fullscreen (also F11, Alt+Enter)"),
    (KEY_K, Action::ToggleKeyboardCapture, "Ctrl+Alt+Shift+K  release/recapture the keyboard (released: keys go to Windows)"),
    (KEY_R, Action::RequestKeyframe, "Ctrl+Alt+Shift+R  request a keyframe (fix a smeared picture)"),
    (KEY_D, Action::Reconnect, "Ctrl+Alt+Shift+D  disconnect and reconnect"),
];

pub fn help() -> String {
    TABLE.iter().map(|t| format!("  {}", t.2)).collect::<Vec<_>>().join("\n")
}

/// Physical modifier state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub win: bool,
}

impl Mods {
    pub fn from_held(held: impl IntoIterator<Item = u16>) -> Mods {
        let mut m = Mods::default();
        for u in held {
            match u {
                HID_LCTRL | HID_RCTRL => m.ctrl = true,
                HID_LALT | HID_RALT => m.alt = true,
                HID_LSHIFT | HID_RSHIFT => m.shift = true,
                HID_LGUI | HID_RGUI => m.win = true,
                _ => {}
            }
        }
        m
    }
}

/// The local action for a key-down of `usage` with modifiers `m` held, if any.
pub fn match_hotkey(m: Mods, usage: u16) -> Option<Action> {
    if usage == KEY_F11 && !m.ctrl && !m.alt && !m.win {
        return Some(Action::ToggleFullscreen);
    }
    if usage == KEY_ENTER && m.alt && !m.ctrl && !m.win {
        return Some(Action::ToggleFullscreen);
    }
    if m.ctrl && m.alt && m.shift && !m.win {
        return TABLE.iter().find(|t| t.0 == usage).map(|t| t.1);
    }
    None
}

/// Next mode for Ctrl+Alt+Shift+M: fast → hybrid → sharp → fast. Without HEVC 4:4:4 decode
/// only fast is possible.
pub fn next_mode(cur: Mode, has444: bool) -> Mode {
    if !has444 {
        return Mode::Fast;
    }
    match cur {
        Mode::Fast => Mode::Hybrid,
        Mode::Hybrid => Mode::Sharp,
        Mode::Sharp => Mode::Fast,
    }
}

pub fn mode_label(m: Mode) -> &'static str {
    match m {
        Mode::Fast => "Fast (4:2:0)",
        Mode::Hybrid => "Hybrid (4:2:0 + 4:4:4 at rest)",
        Mode::Sharp => "Sharp (4:4:4)",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CAS: Mods = Mods { ctrl: true, alt: true, shift: true, win: false };

    #[test]
    fn letter_hotkeys_need_ctrl_alt_shift() {
        assert_eq!(match_hotkey(CAS, KEY_H), Some(Action::ToggleHud));
        assert_eq!(match_hotkey(CAS, KEY_M), Some(Action::CycleMode));
        assert_eq!(match_hotkey(CAS, KEY_F), Some(Action::ToggleFullscreen));
        assert_eq!(match_hotkey(CAS, KEY_K), Some(Action::ToggleKeyboardCapture));
        assert_eq!(match_hotkey(CAS, KEY_R), Some(Action::RequestKeyframe));
        assert_eq!(match_hotkey(CAS, KEY_D), Some(Action::Reconnect));
        assert_eq!(match_hotkey(CAS, 0x04 /* A */), None);
        // missing any modifier → forwarded to the host as usual (e.g. Cmd+Shift+H, Cmd+Opt+H)
        for m in [
            Mods { ctrl: false, ..CAS },
            Mods { alt: false, ..CAS },
            Mods { shift: false, ..CAS },
            Mods { win: true, ..CAS },
            Mods::default(),
        ] {
            assert_eq!(match_hotkey(m, KEY_H), None, "{m:?}");
        }
    }

    #[test]
    fn fullscreen_keys() {
        assert_eq!(match_hotkey(Mods::default(), KEY_F11), Some(Action::ToggleFullscreen));
        assert_eq!(match_hotkey(Mods { shift: true, ..Default::default() }, KEY_F11), Some(Action::ToggleFullscreen));
        assert_eq!(match_hotkey(Mods { ctrl: true, ..Default::default() }, KEY_F11), None, "Cmd+F11 goes to the Mac");
        assert_eq!(match_hotkey(Mods { alt: true, ..Default::default() }, KEY_ENTER), Some(Action::ToggleFullscreen));
        assert_eq!(match_hotkey(Mods::default(), KEY_ENTER), None);
        assert_eq!(match_hotkey(Mods { alt: true, ctrl: true, ..Default::default() }, KEY_ENTER), None);
    }

    #[test]
    fn mods_from_physical_keys() {
        let m = Mods::from_held([HID_RCTRL, HID_LALT, HID_RSHIFT, 0x04]);
        assert_eq!(m, CAS);
        assert_eq!(Mods::from_held([HID_LGUI]), Mods { win: true, ..Default::default() });
    }

    #[test]
    fn mode_cycle() {
        assert_eq!(next_mode(Mode::Fast, true), Mode::Hybrid);
        assert_eq!(next_mode(Mode::Hybrid, true), Mode::Sharp);
        assert_eq!(next_mode(Mode::Sharp, true), Mode::Fast);
        assert_eq!(next_mode(Mode::Fast, false), Mode::Fast);
        assert_eq!(next_mode(Mode::Sharp, false), Mode::Fast);
    }

    #[test]
    fn action_codes_roundtrip() {
        for t in TABLE {
            assert_eq!(Action::from_u8(t.1 as u8), Some(t.1));
        }
        assert_eq!(Action::from_u8(0), None);
        assert_eq!(Action::from_name("Mode"), Some(Action::CycleMode));
        assert_eq!(Action::from_name("x"), None);
        assert!(help().lines().count() == TABLE.len());
    }
}
