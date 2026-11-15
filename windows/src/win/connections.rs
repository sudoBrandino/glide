//! Connections window (tray / Glide menu → Connections…): the saved Macs, with Connect, Add,
//! Edit, Duplicate, Remove and Unpair. The model and its rules live in `crate::connections`;
//! this is the Win32 UI on top of it.
//!
//! Switching to another connection saves it as the active one and restarts the viewer onto it
//! (the same `--after-setup` restart the Set up dialog uses): the session thread resolves its
//! target once, at startup.

use crate::connections as logic;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Make `id` the active connection; restart the viewer onto it if the target changed.
/// Errors are shown to the user.
pub fn switch_to(hwnd: HWND, id: &str) {
    let mut res = Ok(false);
    super::app::update_store(|c| res = logic::activate(c, id));
    match res {
        Ok(true) => restart(hwnd),
        Ok(false) => {}
        Err(e) => error_box(Some(hwnd), &e),
    }
}

/// Start a fresh viewer (it reads the new active connection) and close this one.
pub(super) fn restart(hwnd: HWND) {
    match super::setup::spawn(&super::setup::current_exe()) {
        Ok(()) => unsafe {
            let _ = DestroyWindow(hwnd);
        },
        Err(e) => error_box(Some(hwnd), &e),
    }
}

fn error_box(owner: Option<HWND>, text: &str) {
    let t: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let _ = MessageBoxW(owner, windows::core::PCWSTR(t.as_ptr()), windows::core::w!("Glide"), MB_OK | MB_ICONWARNING);
    }
}

/// Show the Connections window (modal to `hwnd`). Returns after it closes; any switch it made
/// has already restarted the viewer.
pub fn manage(hwnd: HWND) {
    // TODO(dialog): implemented in the Connections window change.
    let _ = hwnd;
}
