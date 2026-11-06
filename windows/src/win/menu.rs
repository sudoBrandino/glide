//! Native Win32 menus for the viewer: the context menu (connection bar / Ctrl+Alt+Shift+Space)
//! and the Glide items in the window's system menu. Contents come from `menu_model`.

use crate::menu_model::{Cmd, Item};
use windows::core::PCSTR;
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::UI::WindowsAndMessaging::*;

/// Opt the process into dark context menus when Windows is in dark app mode. Uses uxtheme's
/// unnamed exports `SetPreferredAppMode` (#135, 1 = AllowDark: follow the system setting) and
/// `FlushMenuThemes` (#136), what Explorer/Notepad use; silently does nothing if unavailable.
pub fn init_dark_mode() {
    unsafe {
        let Ok(ux) = LoadLibraryW(windows::core::w!("uxtheme.dll")) else { return };
        if let Some(set_mode) = GetProcAddress(ux, PCSTR(135 as *const u8)) {
            let set_mode: unsafe extern "system" fn(i32) -> i32 = std::mem::transmute(set_mode);
            set_mode(1);
            if let Some(flush) = GetProcAddress(ux, PCSTR(136 as *const u8)) {
                let flush: unsafe extern "system" fn() = std::mem::transmute(flush);
                flush();
            }
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Append `items` to `menu` (submenus are owned by, and destroyed with, their parent).
unsafe fn append(menu: HMENU, items: &[Item]) {
    for it in items {
        let mut mii = MENUITEMINFOW { cbSize: std::mem::size_of::<MENUITEMINFOW>() as u32, ..Default::default() };
        let mut text: Vec<u16>;
        match it {
            Item::Separator => {
                mii.fMask = MIIM_FTYPE;
                mii.fType = MFT_SEPARATOR;
            }
            Item::Info(t) => {
                text = wide(t);
                mii.fMask = MIIM_STRING | MIIM_STATE;
                mii.fState = MFS_DISABLED;
                mii.dwTypeData = windows::core::PWSTR(text.as_mut_ptr());
            }
            Item::Cmd { cmd, label, checked, radio, enabled } => {
                text = wide(label);
                mii.fMask = MIIM_STRING | MIIM_STATE | MIIM_ID | MIIM_FTYPE;
                mii.fType = if *radio { MFT_RADIOCHECK } else { MFT_STRING };
                mii.wID = cmd.id();
                let mut st = MENU_ITEM_STATE(0);
                if *checked {
                    st |= MFS_CHECKED;
                }
                if !*enabled {
                    st |= MFS_DISABLED;
                }
                mii.fState = st;
                mii.dwTypeData = windows::core::PWSTR(text.as_mut_ptr());
            }
            Item::Sub { label, enabled, items } => {
                let Ok(sub) = CreatePopupMenu() else { continue };
                append(sub, items);
                text = wide(label);
                mii.fMask = MIIM_STRING | MIIM_STATE | MIIM_SUBMENU;
                mii.hSubMenu = sub;
                mii.fState = if *enabled { MENU_ITEM_STATE(0) } else { MFS_DISABLED };
                mii.dwTypeData = windows::core::PWSTR(text.as_mut_ptr());
            }
        }
        let n = GetMenuItemCount(Some(menu)).max(0) as u32;
        let _ = InsertMenuItemW(menu, n, true, &mii);
    }
}

/// Where to anchor the popup.
pub enum Anchor {
    /// Top-center at this screen point (below the connection bar tab).
    Below(POINT),
    /// At the mouse pointer.
    Cursor,
}

/// Show the context menu (modal) and return the chosen command.
pub fn track(hwnd: HWND, items: &[Item], anchor: Anchor) -> Option<Cmd> {
    unsafe {
        let menu = CreatePopupMenu().ok()?;
        append(menu, items);
        let (pt, flags) = match anchor {
            Anchor::Below(p) => (p, TPM_CENTERALIGN | TPM_TOPALIGN),
            Anchor::Cursor => {
                let mut p = POINT::default();
                let _ = GetCursorPos(&mut p);
                (p, TPM_LEFTALIGN | TPM_TOPALIGN)
            }
        };
        let _ = SetForegroundWindow(hwnd);
        let r = TrackPopupMenuEx(menu, (flags | TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY).0, pt.x, pt.y, hwnd, None);
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        Cmd::from_id(r.0 as u32)
    }
}

/// Number of default items in the system menu (before ours).
static SYS_BASE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

/// (Re)fill the Glide part of the window's system menu with `items`, in place (safe to call from
/// WM_INITMENU, so the check marks are current when it opens).
pub fn refresh_system_menu(hwnd: HWND, items: &[Item]) {
    use std::sync::atomic::Ordering;
    unsafe {
        let sys = GetSystemMenu(hwnd, false);
        if sys.is_invalid() {
            return;
        }
        let count = GetMenuItemCount(Some(sys));
        let base = match SYS_BASE.load(Ordering::Relaxed) {
            -1 => {
                SYS_BASE.store(count, Ordering::Relaxed);
                count
            }
            b => b,
        };
        // DeleteMenu by position also destroys submenus.
        for pos in (base..GetMenuItemCount(Some(sys))).rev() {
            let _ = DeleteMenu(sys, pos as u32, MF_BYPOSITION);
        }
        append(sys, items);
    }
}
