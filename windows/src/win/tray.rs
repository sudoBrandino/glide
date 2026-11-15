//! Notification-area (tray) icon: tooltip = window title; left click brings the viewer to
//! the front; right click opens Connect / Disconnect / Reconnect / Stats / Mute / received files /
//! cancel file transfer / Allow the Mac to pair / Set up / Open config / Forget host (unpair) /
//! Quit. `notify` shows a notification balloon (file transfer results). Commands arrive at the
//! viewer window as WM_COMMAND.

use std::sync::OnceLock;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuCmd {
    Connect,
    Disconnect,
    Reconnect,
    ToggleHud,
    ToggleMute,
    OpenConfig,
    ForgetHost,
    CancelFiles,
    OpenDownloads,
    Quit,
    SetUp,
    AllowPairing,
}

/// What the menu shows (enabled/checked state).
pub struct MenuState {
    pub paused: bool,
    pub hud_on: bool,
    /// None = audio disabled; Some(muted).
    pub audio: Option<bool>,
    /// The host paired for the current target (name), if any: enables "Forget host (unpair)".
    pub paired: Option<String>,
    /// None = file transfer off; Some(a transfer is running).
    pub files: Option<bool>,
    /// Listening and not paired: minutes left in the inbound pairing window (0 = closed), which
    /// "Allow the Mac to pair" (re)opens. None = hide the item.
    pub allow_pairing: Option<u64>,
}

const BASE: u16 = 0x4100;
const CMDS: [MenuCmd; 12] = [
    MenuCmd::Connect,
    MenuCmd::Disconnect,
    MenuCmd::Reconnect,
    MenuCmd::ToggleHud,
    MenuCmd::ToggleMute,
    MenuCmd::OpenConfig,
    MenuCmd::ForgetHost,
    MenuCmd::CancelFiles,
    MenuCmd::OpenDownloads,
    MenuCmd::Quit,
    MenuCmd::SetUp,
    MenuCmd::AllowPairing,
];

impl MenuCmd {
    fn id(self) -> u16 {
        BASE + CMDS.iter().position(|c| *c == self).unwrap() as u16
    }
    pub fn from_id(id: u16) -> Option<MenuCmd> {
        CMDS.get(id.checked_sub(BASE)? as usize).copied()
    }
}

pub fn is_menu_id(id: u16) -> bool {
    MenuCmd::from_id(id).is_some()
}

/// "TaskbarCreated" (Explorer restarted → re-add the icon).
pub fn taskbar_created_msg() -> u32 {
    static MSG: OnceLock<u32> = OnceLock::new();
    *MSG.get_or_init(|| unsafe {
        match RegisterWindowMessageW(w!("TaskbarCreated")) {
            0 => u32::MAX,
            m => m,
        }
    })
}

#[derive(Clone)]
pub struct Tray {
    hwnd: isize,
    msg: u32,
    icon: isize,
}

fn wcopy(dst: &mut [u16], s: &str) {
    let n = dst.len() - 1;
    let mut i = 0;
    for c in s.encode_utf16().take(n) {
        dst[i] = c;
        i += 1;
    }
    dst[i] = 0;
}

impl Tray {
    pub fn new(hwnd: HWND, msg: u32) -> Tray {
        let size = unsafe { GetSystemMetrics(SM_CXSMICON) };
        let icon = super::prompt::app_icon(size).or_else(|| unsafe { LoadIconW(None, IDI_APPLICATION).ok() }).unwrap_or_default();
        let _ = taskbar_created_msg();
        Tray { hwnd: hwnd.0 as isize, msg, icon: icon.0 as isize }
    }

    fn data(&self, flags: NOTIFY_ICON_DATA_FLAGS) -> NOTIFYICONDATAW {
        let mut d = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: HWND(self.hwnd as *mut _),
            uID: 1,
            uFlags: flags,
            uCallbackMessage: self.msg,
            hIcon: HICON(self.icon as *mut _),
            ..Default::default()
        };
        d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        d
    }

    pub fn add(&self) {
        let mut d = self.data(NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        wcopy(&mut d.szTip, "Glide");
        unsafe {
            if Shell_NotifyIconW(NIM_ADD, &d).as_bool() {
                let _ = Shell_NotifyIconW(NIM_SETVERSION, &d);
            }
        }
    }

    pub fn set_tip(&self, tip: &str) {
        let mut d = self.data(NIF_TIP | NIF_SHOWTIP);
        wcopy(&mut d.szTip, tip);
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
        }
    }

    /// A notification balloon/toast from the tray icon (clicks arrive as NIN_BALLOONUSERCLICK).
    pub fn notify(&self, title: &str, body: &str) {
        let mut d = self.data(NIF_INFO);
        wcopy(&mut d.szInfoTitle, title);
        wcopy(&mut d.szInfo, body);
        d.dwInfoFlags = NIIF_INFO;
        unsafe {
            let _ = Shell_NotifyIconW(NIM_MODIFY, &d);
        }
    }

    pub fn remove(&self) {
        let d = self.data(NOTIFY_ICON_DATA_FLAGS(0));
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &d);
        }
    }
}

fn bring_to_front(hwnd: HWND) {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
    }
}

/// Tray callback (NOTIFYICON_VERSION_4: LOWORD(lParam) = event).
pub fn on_notify(hwnd: HWND, lparam: LPARAM, st: &MenuState) {
    const NIN_KEYSELECT: u32 = NIN_SELECT | 1; // NIN_SELECT | NINF_KEY
    let ev = (lparam.0 & 0xFFFF) as u32;
    match ev {
        WM_CONTEXTMENU | WM_RBUTTONUP => show_menu(hwnd, st),
        NIN_SELECT | NIN_KEYSELECT | WM_LBUTTONDBLCLK => bring_to_front(hwnd),
        _ => {}
    }
}

fn show_menu(hwnd: HWND, st: &MenuState) {
    let (paused, hud_on) = (st.paused, st.hud_on);
    unsafe {
        let Ok(m) = CreatePopupMenu() else { return };
        let item = |cmd: MenuCmd, text: &str, flags: MENU_ITEM_FLAGS| {
            let t: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
            let _ = AppendMenuW(m, MF_STRING | flags, cmd.id() as usize, PCWSTR(t.as_ptr()));
        };
        let gray = |b: bool| if b { MF_GRAYED } else { MF_ENABLED };
        item(MenuCmd::Connect, "&Connect", gray(!paused));
        item(MenuCmd::Disconnect, "&Disconnect", gray(paused));
        item(MenuCmd::Reconnect, "&Reconnect\tCtrl+Alt+Shift+D", gray(paused));
        let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        item(MenuCmd::ToggleHud, "&Stats overlay\tCtrl+Alt+Shift+H", if hud_on { MF_CHECKED } else { MF_UNCHECKED });
        if let Some(muted) = st.audio {
            item(MenuCmd::ToggleMute, "&Mute audio\tCtrl+Alt+Shift+A", if muted { MF_CHECKED } else { MF_UNCHECKED });
        }
        if let Some(busy) = st.files {
            let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
            item(MenuCmd::OpenDownloads, "Open &received files folder", MF_ENABLED);
            item(MenuCmd::CancelFiles, "Cancel file &transfer\tCtrl+Alt+Shift+X", gray(!busy));
            let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        }
        if let Some(left) = st.allow_pairing {
            let text = match left {
                0 => format!("Allow the Mac to &pair ({} min)", crate::peers::INBOUND_PAIRING_WINDOW.as_secs() / 60),
                n => format!("Allow the Mac to &pair (allowed, {n} min left)"),
            };
            item(MenuCmd::AllowPairing, &text, MF_ENABLED);
        }
        item(MenuCmd::SetUp, "Set &up…", MF_ENABLED);
        item(MenuCmd::OpenConfig, "Open &config file", MF_ENABLED);
        let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        match &st.paired {
            Some(name) => item(MenuCmd::ForgetHost, &format!("&Forget host “{}” (unpair)…", name.replace('&', "&&")), MF_ENABLED),
            None => item(MenuCmd::ForgetHost, "&Forget host (unpair) — not paired", MF_GRAYED),
        }
        let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        let ver: Vec<u16> = format!("Glide {}", crate::version::display()).encode_utf16().chain(std::iter::once(0)).collect();
        let _ = AppendMenuW(m, MF_STRING | MF_GRAYED, 0, PCWSTR(ver.as_ptr()));
        item(MenuCmd::Quit, "&Quit Glide", MF_ENABLED);
        let mut pt = POINT::default();
        let _ = GetCursorPos(&mut pt);
        // Required so the menu closes when clicking elsewhere (KB135788).
        let _ = SetForegroundWindow(hwnd);
        let _ = TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, None, hwnd, None);
        let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(m);
    }
}

/// Open the config file in Notepad (always present; .json may have no association).
pub fn open_in_editor(path: &std::path::Path) {
    let p: Vec<u16> = format!("\"{}\"", path.display()).encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        ShellExecuteW(None, w!("open"), w!("notepad.exe"), PCWSTR(p.as_ptr()), None, SW_SHOWNORMAL);
    }
}
