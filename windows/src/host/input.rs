//! Input injection logic without Win32: HID usage → Windows scancode (the inverse of `crate::hid`),
//! held key/button tracking (released on ReleaseAll and on disconnect), wheel accumulation and the
//! absolute mouse mapping onto the captured output. `host::win::inject` turns these into
//! SendInput calls.

use crate::hid::{scancode_to_hid, EXT, HID_NUMLOCK, HID_PAUSE, HID_PRINTSCREEN};
use std::collections::BTreeSet;

/// Windows wheel units per notch.
pub const WHEEL_DELTA: f32 = 120.0;

/// How to inject one key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCode {
    /// Set-1 scancode; `EXT` (0xE000) set = E0-prefixed (KEYEVENTF_EXTENDEDKEY).
    Scan(u16),
    /// Virtual-key code (keys without a usable scancode: Pause, Num Lock, IME keys);
    /// `extended` = KEYEVENTF_EXTENDEDKEY.
    Vk { vk: u16, extended: bool },
}

pub const VK_PAUSE: u16 = 0x13;
pub const VK_NUMLOCK: u16 = 0x90;
pub const VK_HANGUL: u16 = 0x15;
pub const VK_HANJA: u16 = 0x19;

/// USB HID Keyboard page usage → how to inject it on Windows. None = not injected (unknown,
/// or deliberately dropped like Power).
pub fn hid_to_key(usage: u16) -> Option<KeyCode> {
    match usage {
        // Scancode 0x45 is Pause/Num Lock depending on E0/E1 prefixes: use VKs.
        HID_PAUSE => return Some(KeyCode::Vk { vk: VK_PAUSE, extended: false }),
        HID_NUMLOCK => return Some(KeyCode::Vk { vk: VK_NUMLOCK, extended: true }),
        0x90 => return Some(KeyCode::Vk { vk: VK_HANGUL, extended: false }), // LANG1
        0x91 => return Some(KeyCode::Vk { vk: VK_HANJA, extended: false }),  // LANG2
        HID_PRINTSCREEN => return Some(KeyCode::Scan(0xE037)),               // not SysRq (0x54, Alt+PrintScreen)
        0x32 => return Some(KeyCode::Scan(0x2B)),                            // Non-US # (ISO) = same key as backslash
        0x66 => return None,                                                 // Power: never let a viewer power off the PC
        _ => {}
    }
    reverse_table().get(usage as usize).copied().flatten().map(KeyCode::Scan)
}

/// usage → scancode built from `crate::hid::scancode_to_hid` (non-extended scancodes win over
/// E0 ones, e.g. Right Shift 0x36 over 0xE036).
fn reverse_table() -> &'static [Option<u16>] {
    static T: std::sync::OnceLock<Vec<Option<u16>>> = std::sync::OnceLock::new();
    T.get_or_init(|| {
        let mut t = vec![None; 256];
        for sc in (0u16..=0x7F).chain(EXT..=EXT | 0xFF) {
            if let Some(u) = scancode_to_hid(sc) {
                if (u as usize) < t.len() && t[u as usize].is_none() {
                    t[u as usize] = Some(sc);
                }
            }
        }
        t
    })
}

/// Mouse buttons as on the wire (0 L, 1 R, 2 M, 3 back, 4 forward).
pub const MAX_BUTTON: u8 = 4;

/// Keys and buttons currently held down by the viewer, so they can all be released (ReleaseAll,
/// disconnect) and nothing stays stuck on the PC.
#[derive(Debug, Default)]
pub struct Held {
    keys: BTreeSet<u16>,
    buttons: BTreeSet<u8>,
}

impl Held {
    /// Records a key event; returns false for an up of a key that isn't held (dropped).
    pub fn key(&mut self, usage: u16, down: bool) -> bool {
        if down {
            self.keys.insert(usage);
            true
        } else {
            self.keys.remove(&usage)
        }
    }
    /// Records a button event; returns false for a duplicate down or an up of a button not held.
    pub fn button(&mut self, b: u8, down: bool) -> bool {
        if down {
            self.buttons.insert(b)
        } else {
            self.buttons.remove(&b)
        }
    }
    /// Everything held, cleared: (key usages, buttons) to release.
    pub fn take_all(&mut self) -> (Vec<u16>, Vec<u8>) {
        (std::mem::take(&mut self.keys).into_iter().collect(), std::mem::take(&mut self.buttons).into_iter().collect())
    }
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty() && self.buttons.is_empty()
    }
}

/// Accumulates fractional wheel notches; emits whole Windows wheel units (1/120 notch).
#[derive(Debug, Default, Clone, Copy)]
pub struct WheelAccumulator {
    rest: f32,
}

impl WheelAccumulator {
    /// Adds `notches`; returns the wheel delta to inject now (0 = nothing yet).
    pub fn add(&mut self, notches: f32) -> i32 {
        self.rest += notches * WHEEL_DELTA;
        let whole = self.rest.trunc();
        self.rest -= whole;
        whole as i32
    }
    pub fn reset(&mut self) {
        self.rest = 0.0;
    }
}

/// A rectangle in virtual-desktop pixels (left/top inclusive, right/bottom exclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PxRect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl PxRect {
    pub fn width(&self) -> i32 {
        self.right - self.left
    }
    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }
}

/// The pixel under normalized (`x`, `y`) on `out` (edges span the display, §3), clamped inside.
pub fn to_pixel(x: f32, y: f32, out: PxRect) -> (i32, i32) {
    let px = out.left as f64 + (x.clamp(0.0, 1.0) as f64) * out.width() as f64;
    let py = out.top as f64 + (y.clamp(0.0, 1.0) as f64) * out.height() as f64;
    ((px.floor() as i32).clamp(out.left, out.right - 1), (py.floor() as i32).clamp(out.top, out.bottom - 1))
}

/// SendInput absolute coordinates (0..=65535 over the virtual desktop, with
/// MOUSEEVENTF_VIRTUALDESK) for pixel (`px`, `py`).
pub fn to_absolute(px: i32, py: i32, vdesk: PxRect) -> (i32, i32) {
    let map = |p: i32, lo: i32, len: i32| -> i32 {
        if len <= 1 {
            return 0;
        }
        // The pixel's center; Windows maps `a` back to pixel `a * len / 65536`.
        let v = ((2 * (p - lo) as i64 + 1) * 65536) / (2 * len as i64);
        v.clamp(0, 65535) as i32
    };
    (map(px, vdesk.left, vdesk.width()), map(py, vdesk.top, vdesk.height()))
}

/// Inverse of `to_absolute` as Windows applies it (for tests).
pub fn from_absolute(ax: i32, ay: i32, vdesk: PxRect) -> (i32, i32) {
    (vdesk.left + ((ax as i64 * vdesk.width() as i64) >> 16) as i32, vdesk.top + ((ay as i64 * vdesk.height() as i64) >> 16) as i32)
}

/// Cursor position normalized over `out`, and whether it is on that output.
pub fn normalize(px: i32, py: i32, out: PxRect) -> (f32, f32, bool) {
    let w = out.width().max(1) as f32;
    let h = out.height().max(1) as f32;
    let inside = px >= out.left && px < out.right && py >= out.top && py < out.bottom;
    (((px - out.left) as f32 + 0.5) / w, ((py - out.top) as f32 + 0.5) / h, inside)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hid::{HID_LCTRL, HID_LGUI, HID_RALT, HID_RCTRL, HID_RSHIFT};

    #[test]
    fn hid_reverse_mapping_round_trips() {
        // Every forward-mapped scancode's usage maps back to a scancode with the same usage.
        for sc in (0u16..=0x7F).chain(EXT..=EXT | 0xFF) {
            if let Some(u) = scancode_to_hid(sc) {
                match hid_to_key(u) {
                    Some(KeyCode::Scan(back)) => assert_eq!(scancode_to_hid(back), Some(u), "usage {u:#x}"),
                    Some(KeyCode::Vk { .. }) => {}
                    None => assert_eq!(u, 0x66, "only Power is dropped"),
                }
            }
        }
        assert_eq!(hid_to_key(0x04), Some(KeyCode::Scan(0x1E))); // A
        assert_eq!(hid_to_key(0x28), Some(KeyCode::Scan(0x1C))); // Enter
        assert_eq!(hid_to_key(0x58), Some(KeyCode::Scan(0xE01C))); // KP Enter
        assert_eq!(hid_to_key(0x4F), Some(KeyCode::Scan(0xE04D))); // Right arrow
        assert_eq!(hid_to_key(0x5E), Some(KeyCode::Scan(0x4D))); // KP 6
        assert_eq!(hid_to_key(HID_LCTRL), Some(KeyCode::Scan(0x1D)));
        assert_eq!(hid_to_key(HID_RCTRL), Some(KeyCode::Scan(0xE01D)));
        assert_eq!(hid_to_key(HID_RALT), Some(KeyCode::Scan(0xE038)));
        assert_eq!(hid_to_key(HID_LGUI), Some(KeyCode::Scan(0xE05B)));
        assert_eq!(hid_to_key(HID_RSHIFT), Some(KeyCode::Scan(0x36)), "non-extended wins");
        assert_eq!(hid_to_key(0x46), Some(KeyCode::Scan(0xE037))); // PrintScreen
        assert_eq!(hid_to_key(0x7F), Some(KeyCode::Scan(0xE020))); // Mute
        assert_eq!(hid_to_key(0x80), Some(KeyCode::Scan(0xE030))); // Volume up
        assert_eq!(hid_to_key(0x64), Some(KeyCode::Scan(0x56))); // ISO key
        assert_eq!(hid_to_key(0x32), Some(KeyCode::Scan(0x2B)));
        assert_eq!(hid_to_key(0x73), Some(KeyCode::Scan(0x76))); // F24
        assert_eq!(hid_to_key(HID_PAUSE), Some(KeyCode::Vk { vk: VK_PAUSE, extended: false }));
        assert_eq!(hid_to_key(HID_NUMLOCK), Some(KeyCode::Vk { vk: VK_NUMLOCK, extended: true }));
        assert_eq!(hid_to_key(0x66), None);
        assert_eq!(hid_to_key(0x00), None);
        assert_eq!(hid_to_key(0xFFFF), None);
    }

    #[test]
    fn held_tracking() {
        let mut h = Held::default();
        assert!(h.key(0x04, true));
        assert!(h.key(0x04, true), "autorepeat is passed on");
        assert!(h.key(0xE1, true));
        assert!(!h.key(0x05, false), "up without down is dropped");
        assert!(h.key(0x04, false));
        assert!(h.button(0, true));
        assert!(!h.button(0, true));
        assert!(h.button(4, true));
        assert_eq!(h.take_all(), (vec![0xE1], vec![0, 4]));
        assert!(h.is_empty());
        assert!(!h.button(0, false));
    }

    #[test]
    fn wheel_accumulates_fractions() {
        let mut w = WheelAccumulator::default();
        assert_eq!(w.add(1.0), 120);
        assert_eq!(w.add(-2.0), -240);
        let mut sum = 0;
        for _ in 0..10 {
            sum += w.add(0.0041); // 0.492 units each
        }
        assert_eq!(sum, 4);
        w.reset();
        assert_eq!(w.add(0.001), 0);
        w.reset();
        assert_eq!(w.add(0.5), 60);
    }

    #[test]
    fn absolute_mapping_hits_the_intended_pixel() {
        // Two monitors: primary 2560x1440 at 0,0; second 1920x1080 at -1920,200.
        let vdesk = PxRect { left: -1920, top: 0, right: 2560, bottom: 1440 };
        let primary = PxRect { left: 0, top: 0, right: 2560, bottom: 1440 };
        let second = PxRect { left: -1920, top: 200, right: 0, bottom: 1280 };
        for out in [primary, second] {
            for &(x, y) in &[(0.0f32, 0.0f32), (1.0, 1.0), (0.5, 0.5), (0.123, 0.987), (-5.0, 7.0)] {
                let (px, py) = to_pixel(x, y, out);
                assert!(px >= out.left && px < out.right && py >= out.top && py < out.bottom);
                let (ax, ay) = to_absolute(px, py, vdesk);
                assert!((0..=65535).contains(&ax) && (0..=65535).contains(&ay));
                assert_eq!(from_absolute(ax, ay, vdesk), (px, py), "{x},{y} on {out:?}");
            }
        }
        assert_eq!(to_pixel(0.0, 0.0, primary), (0, 0));
        assert_eq!(to_pixel(1.0, 1.0, primary), (2559, 1439));
        // Viewers send pixel centers: (px + 0.5) / w maps back to px.
        assert_eq!(to_pixel(100.5 / 2560.0, 7.5 / 1440.0, primary), (100, 7));
    }

    #[test]
    fn cursor_normalization() {
        let out = PxRect { left: 100, top: 0, right: 300, bottom: 100 };
        assert_eq!(normalize(100, 0, out), (0.5 / 200.0, 0.5 / 100.0, true));
        assert!(!normalize(300, 50, out).2);
        assert!(!normalize(99, 50, out).2);
        let (x, y, _) = normalize(199, 49, out);
        assert_eq!(to_pixel(x, y, out), (199, 49));
    }
}
