//! SendInput: keys by scancode (KEYEVENTF_SCANCODE, KEYEVENTF_EXTENDEDKEY for E0 keys) from HID
//! usages, absolute mouse over the captured output (MOUSEEVENTF_ABSOLUTE | VIRTUALDESK), buttons
//! incl. X buttons, wheel / horizontal wheel in WHEEL_DELTA units with fractions accumulated.
//! Everything held is released on ReleaseAll and when the session ends (Drop).
//!
//! SendInput is blocked by UIPI for windows of elevated processes when the host isn't elevated,
//! and does nothing while the secure desktop (UAC, lock screen) is up; failures are logged
//! (rate-limited) and the session continues.

use crate::host::input::{hid_to_key, to_absolute, to_pixel, Held, KeyCode, PxRect, WheelAccumulator};
use crate::host::log;
use crate::host::stream::InputEvent;
use crate::protocol::{MOUSE_BACK, MOUSE_FORWARD, MOUSE_LEFT, MOUSE_MIDDLE, MOUSE_RIGHT};
use std::time::Instant;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, XBUTTON1, XBUTTON2,
};

pub struct Injector {
    held: Held,
    wheel_x: WheelAccumulator,
    wheel_y: WheelAccumulator,
    /// The captured output in virtual-desktop pixels.
    pub output: PxRect,
    failures: u32,
    last_failure_log: Option<Instant>,
}

pub fn virtual_desktop() -> PxRect {
    unsafe {
        let (x, y) = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN));
        let (w, h) = (GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));
        PxRect { left: x, top: y, right: x + w.max(1), bottom: y + h.max(1) }
    }
}

fn mouse(dx: i32, dy: i32, data: u32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn key_input(code: KeyCode, down: bool) -> INPUT {
    let up = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
    let ki = match code {
        KeyCode::Scan(sc) => {
            let ext = if sc & crate::hid::EXT != 0 { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: sc & 0xFF, dwFlags: KEYEVENTF_SCANCODE | ext | up, time: 0, dwExtraInfo: 0 }
        }
        KeyCode::Vk { vk, extended } => {
            let ext = if extended { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: 0, dwFlags: ext | up, time: 0, dwExtraInfo: 0 }
        }
    };
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki } }
}

fn button_input(b: u8, down: bool) -> Option<INPUT> {
    let (flags, data) = match (b, down) {
        (MOUSE_LEFT, true) => (MOUSEEVENTF_LEFTDOWN, 0),
        (MOUSE_LEFT, false) => (MOUSEEVENTF_LEFTUP, 0),
        (MOUSE_RIGHT, true) => (MOUSEEVENTF_RIGHTDOWN, 0),
        (MOUSE_RIGHT, false) => (MOUSEEVENTF_RIGHTUP, 0),
        (MOUSE_MIDDLE, true) => (MOUSEEVENTF_MIDDLEDOWN, 0),
        (MOUSE_MIDDLE, false) => (MOUSEEVENTF_MIDDLEUP, 0),
        (MOUSE_BACK, true) => (MOUSEEVENTF_XDOWN, XBUTTON1 as u32),
        (MOUSE_BACK, false) => (MOUSEEVENTF_XUP, XBUTTON1 as u32),
        (MOUSE_FORWARD, true) => (MOUSEEVENTF_XDOWN, XBUTTON2 as u32),
        (MOUSE_FORWARD, false) => (MOUSEEVENTF_XUP, XBUTTON2 as u32),
        _ => return None,
    };
    Some(mouse(0, 0, data, flags))
}

impl Injector {
    pub fn new(output: PxRect) -> Injector {
        Injector {
            held: Held::default(),
            wheel_x: WheelAccumulator::default(),
            wheel_y: WheelAccumulator::default(),
            output,
            failures: 0,
            last_failure_log: None,
        }
    }

    fn send(&mut self, inputs: &[INPUT]) {
        if inputs.is_empty() {
            return;
        }
        let n = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
        if (n as usize) < inputs.len() {
            self.failures += 1;
            let now = Instant::now();
            if self.last_failure_log.is_none_or(|t| now.duration_since(t).as_secs() >= 10) {
                log(&format!(
                    "input: SendInput injected {n} of {} events ({}; {} failures so far): the secure desktop (UAC / lock screen) or an elevated window has the input",
                    inputs.len(),
                    windows::core::Error::from_thread().message(),
                    self.failures
                ));
                self.last_failure_log = Some(now);
            }
        }
    }

    pub fn handle(&mut self, ev: &InputEvent) {
        match *ev {
            InputEvent::MouseMove { x, y } => {
                let (px, py) = to_pixel(x, y, self.output);
                let (ax, ay) = to_absolute(px, py, virtual_desktop());
                self.send(&[mouse(ax, ay, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)]);
            }
            InputEvent::MouseButton { button, down } => {
                if self.held.button(button, down) {
                    if let Some(i) = button_input(button, down) {
                        self.send(&[i]);
                    }
                }
            }
            InputEvent::Wheel { dx, dy } => {
                let mut v = Vec::new();
                let y = self.wheel_y.add(dy);
                if y != 0 {
                    v.push(mouse(0, 0, y as u32, MOUSEEVENTF_WHEEL));
                }
                let x = self.wheel_x.add(dx);
                if x != 0 {
                    v.push(mouse(0, 0, x as u32, MOUSEEVENTF_HWHEEL));
                }
                self.send(&v);
            }
            InputEvent::Key { usage, down } => {
                let Some(code) = hid_to_key(usage) else { return };
                if self.held.key(usage, down) {
                    self.send(&[key_input(code, down)]);
                }
            }
            InputEvent::ReleaseAll => self.release_all(),
        }
    }

    /// Releases every key and button the viewer holds.
    pub fn release_all(&mut self) {
        let (keys, buttons) = self.held.take_all();
        let mut v: Vec<INPUT> = keys.iter().filter_map(|&u| hid_to_key(u).map(|c| key_input(c, false))).collect();
        v.extend(buttons.iter().filter_map(|&b| button_input(b, false)));
        self.wheel_x.reset();
        self.wheel_y.reset();
        if !v.is_empty() {
            log(&format!("input: releasing {} keys and {} buttons", keys.len(), buttons.len()));
        }
        self.send(&v);
    }
}

impl Drop for Injector {
    fn drop(&mut self) {
        self.release_all();
    }
}
