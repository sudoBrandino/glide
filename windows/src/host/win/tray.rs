//! The host's notification-area icon (own hidden window and message loop on a dedicated thread):
//! right click → "Pair New Mac…" (the label the Mac viewer tells users to look for), "Paired
//! Macs" ▸ name ▸ Remove…, "Open config file", "Quit Glide Host". Left click opens the menu too.

use crate::host::log;
use std::cell::RefCell;
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// What the menu does; called on the tray thread.
pub struct TrayActions {
    /// Opens the pairing window.
    pub pair: Box<dyn Fn() + Send>,
    /// Seconds left in the pairing window (None = closed).
    pub pairing_left: Box<dyn Fn() -> Option<u64> + Send>,
    /// (name, fingerprint, key hex) of each paired Mac.
    pub paired: Box<dyn Fn() -> Vec<(String, String, String)> + Send>,
    /// Unpair by key hex.
    pub unpair: Box<dyn Fn(&str) + Send>,
    pub config_path: std::path::PathBuf,
    pub quit: Box<dyn Fn() + Send>,
}

const WM_TRAY: u32 = WM_APP + 1;
const ID_PAIR: usize = 1;
const ID_CONFIG: usize = 2;
const ID_QUIT: usize = 3;
const ID_UNPAIR_BASE: usize = 100;

struct State {
    actions: TrayActions,
    keys: Vec<(String, String)>,
    icon: HICON,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
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

fn icon_data(hwnd: HWND, icon: HICON) -> NOTIFYICONDATAW {
    let mut d = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
        uCallbackMessage: WM_TRAY,
        hIcon: icon,
        ..Default::default()
    };
    wcopy(&mut d.szTip, "Glide Host — this PC can be controlled from a paired Mac");
    d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
    d
}

/// Starts the tray thread. Returns at once; failures are logged (the console still works).
pub fn start(actions: TrayActions) {
    std::thread::spawn(move || unsafe {
        let Ok(hinst) = GetModuleHandleW(None) else { return };
        let class = w!("GlideHostTray");
        let wc = WNDCLASSW { lpfnWndProc: Some(wnd_proc), hInstance: hinst.into(), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
        let hwnd = match CreateWindowExW(WINDOW_EX_STYLE(0), class, w!("Glide Host"), WS_OVERLAPPED, 0, 0, 0, 0, None, None, Some(hinst.into()), None)
        {
            Ok(h) => h,
            Err(e) => {
                log(&format!("tray: no window ({e}); use the console commands"));
                return;
            }
        };
        let size = GetSystemMetrics(SM_CXSMICON);
        let icon = crate::win::prompt::app_icon(size).or_else(|| LoadIconW(None, IDI_APPLICATION).ok()).unwrap_or_default();
        STATE.with(|s| *s.borrow_mut() = Some(State { actions, keys: Vec::new(), icon }));
        let d = icon_data(hwnd, icon);
        if Shell_NotifyIconW(NIM_ADD, &d).as_bool() {
            let _ = Shell_NotifyIconW(NIM_SETVERSION, &d);
        } else {
            log("tray: couldn't add the notification icon (no shell?); use the console commands");
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    });
}

fn taskbar_created() -> u32 {
    unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) }
}

unsafe extern "system" fn wnd_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY => {
            let ev = (lp.0 & 0xFFFF) as u32;
            if matches!(ev, WM_CONTEXTMENU | WM_RBUTTONUP | WM_LBUTTONUP) || ev == NIN_SELECT || ev == NIN_SELECT | 1 {
                show_menu(hwnd);
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = wp.0 & 0xFFFF;
            STATE.with(|s| {
                let s = s.borrow();
                let Some(st) = s.as_ref() else { return };
                match id {
                    ID_PAIR => (st.actions.pair)(),
                    ID_CONFIG => {
                        let p = wide(&format!("\"{}\"", st.actions.config_path.display()));
                        ShellExecuteW(None, w!("open"), w!("notepad.exe"), PCWSTR(p.as_ptr()), None, SW_SHOWNORMAL);
                    }
                    ID_QUIT => (st.actions.quit)(),
                    n if n >= ID_UNPAIR_BASE => {
                        if let Some((name, key)) = st.keys.get(n - ID_UNPAIR_BASE) {
                            let text = wide(&format!(
                                "Remove “{name}”? That Mac will have to pair again to control this PC, and its session (if any) ends."
                            ));
                            if MessageBoxW(Some(hwnd), PCWSTR(text.as_ptr()), w!("Glide Host"), MB_OKCANCEL | MB_ICONQUESTION | MB_DEFBUTTON2) == IDOK
                            {
                                (st.actions.unpair)(key);
                            }
                        }
                    }
                    _ => {}
                }
            });
            LRESULT(0)
        }
        m if m == taskbar_created() && m != 0 => {
            // Explorer restarted: add the icon again.
            STATE.with(|s| {
                if let Some(st) = s.borrow().as_ref() {
                    let _ = Shell_NotifyIconW(NIM_ADD, &icon_data(hwnd, st.icon));
                }
            });
            LRESULT(0)
        }
        WM_DESTROY => {
            STATE.with(|s| {
                if let Some(st) = s.borrow().as_ref() {
                    let _ = Shell_NotifyIconW(NIM_DELETE, &icon_data(hwnd, st.icon));
                }
            });
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

unsafe fn show_menu(hwnd: HWND) {
    let Ok(m) = CreatePopupMenu() else { return };
    let add = |menu: HMENU, id: usize, text: &str, flags: MENU_ITEM_FLAGS| {
        let t = wide(text);
        let _ = AppendMenuW(menu, MF_STRING | flags, id, PCWSTR(t.as_ptr()));
    };
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let Some(st) = s.as_mut() else { return };
        match (st.actions.pairing_left)() {
            Some(left) => add(m, ID_PAIR, &format!("Pair New Mac… (open, {}:{:02} left)", left / 60, left % 60), MF_ENABLED),
            None => add(m, ID_PAIR, "Pair New Mac…", MF_ENABLED),
        }
        let paired = (st.actions.paired)();
        st.keys = paired.iter().map(|(n, _, k)| (n.clone(), k.clone())).collect();
        if let Ok(sub) = CreatePopupMenu() {
            if paired.is_empty() {
                add(sub, 0, "(none)", MF_GRAYED);
            }
            for (i, (name, fp, _)) in paired.iter().enumerate() {
                add(sub, ID_UNPAIR_BASE + i, &format!("Remove “{}” ({fp})…", name.replace('&', "&&")), MF_ENABLED);
            }
            let t = wide("Paired Macs");
            let _ = AppendMenuW(m, MF_POPUP, sub.0 as usize, PCWSTR(t.as_ptr()));
        }
        add(m, ID_CONFIG, "Open config file", MF_ENABLED);
        let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
        add(m, 0, &format!("Glide Host {}", env!("CARGO_PKG_VERSION")), MF_GRAYED);
        add(m, ID_QUIT, "Quit Glide Host", MF_ENABLED);
    });
    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    // Required so the menu closes when clicking elsewhere (KB135788).
    let _ = SetForegroundWindow(hwnd);
    let _ = TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, None, hwnd, None);
    let _ = PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0));
    let _ = DestroyMenu(m);
}
