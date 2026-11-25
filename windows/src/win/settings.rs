//! Settings window (Glide menu / tray → Settings…). The model and its rules live in
//! `crate::settings`; this is the Win32 UI on top of it.
//!
//! - `IDD_SETTINGS` (res/glide.rc): a page list on the left and every page's controls in one
//!   template; only the selected page's controls (ids `PAGE_BASE + PAGE_SPAN * page ..`) and its
//!   group box are shown. OK / Cancel / Apply at the bottom, above them a status line for
//!   validation errors (red) and what was saved.
//! - OK / Apply validate (`logic::validate`; a bad field's page is shown and the field focused),
//!   write start at sign-in, save the changed fields (`logic::apply`) and switch what applies at
//!   once (`app::apply_live_settings`). What only a restart picks up is collected; after the
//!   window closes Glide offers to restart (the `--after-setup` restart of `connections`), never
//!   inside the modal loop.
//! - Unpair, Forget remembered displays and Reset change the draft only: nothing is saved before
//!   OK or Apply.
//!
//! Test hook (`test-hooks` builds only, see `util::test_hook`): `GLIDE_SETTINGS_DUMP=x.bmp` prints
//! the draft as text, saves a capture of every page (`x-1.bmp` … `x-8.bmp`) after ~0.5 s and
//! closes the window.

use crate::settings::{self as logic, Draft, Field, Page, PairedRow, Running, Settings};
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{GetSysColorBrush, SetBkMode, SetTextColor, UpdateWindow, COLOR_BTNFACE, HDC, TRANSPARENT};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, GetFocus, IsWindowEnabled, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_SETTINGS: u16 = 106;
const IDC_PAGES: i32 = 1500;
/// Group box of page `p`: `IDC_GROUP + p`.
const IDC_GROUP: i32 = 1501;
const IDC_STATUS: i32 = 1590;
const IDC_APPLY: i32 = 1591;
const PAGE_BASE: i32 = 1600;
const PAGE_SPAN: i32 = 20;

// General
const IDC_AUTOSTART: i32 = 1600;
const IDC_CONNECT_AT_SIGNIN: i32 = 1601;
const IDC_SIGNIN_NOTE: i32 = 1602;
const IDC_BAR_PINNED: i32 = 1603;
const IDC_HUD: i32 = 1604;
// Picture
const IDC_MODE: i32 = 1621;
const IDC_MODE_HELP: i32 = 1622;
const IDC_FORGET_DISPLAYS: i32 = 1624;
const IDC_DISPLAYS_NOTE: i32 = 1625;
// Keyboard and mouse
const IDC_CTRL_AS_CMD: i32 = 1640;
const IDC_NATURAL: i32 = 1642;
// Audio
const IDC_AUDIO: i32 = 1660;
const IDC_MUTED: i32 = 1661;
const IDC_AUDIO_NOTE: i32 = 1662;
// Clipboard
const IDC_CLIPBOARD: i32 = 1680;
const IDC_SECRETS: i32 = 1681;
const IDC_SECRETS_WARN: i32 = 1682;
// Files
const IDC_FILES: i32 = 1700;
const IDC_RECEIVE: i32 = 1701;
const IDC_DIR: i32 = 1703;
const IDC_BROWSE: i32 = 1704;
const IDC_DIR_DEFAULT: i32 = 1705;
const IDC_MAX_SIZE: i32 = 1707;
const IDC_MAX_FILES: i32 = 1709;
// Network and security
const IDC_PORT: i32 = 1721;
const IDC_ACCEPT: i32 = 1723;
const IDC_PEERS: i32 = 1725;
const IDC_PAIRED: i32 = 1727;
const IDC_UNPAIR: i32 = 1728;
const IDC_FINGERPRINT: i32 = 1730;
const IDC_COPY: i32 = 1731;
// Advanced
const IDC_CONFIG_PATH: i32 = 1741;
const IDC_OPEN_CONFIG: i32 = 1742;
const IDC_RESET: i32 = 1744;

/// The Files page controls that only matter while file transfer is on.
const FILE_DETAILS: [i32; 10] = [IDC_RECEIVE, 1702, IDC_DIR, IDC_BROWSE, IDC_DIR_DEFAULT, 1706, IDC_MAX_SIZE, 1708, IDC_MAX_FILES, 1710];

const HOOK_TIMER: usize = 1;
const TITLE: PCWSTR = w!("Glide — Settings");
const RED: COLORREF = COLORREF(0x0000_20C0);

/// Show the Settings window (modal to `hwnd`). Returns after it closes, and after the restart it
/// offered, if any.
pub fn show(hwnd: HWND) {
    init_common_controls();
    let store = super::app::store_snapshot();
    let initial = Settings::from_config(&store.config, super::setup::autostart_on());
    let (running, has444) = super::app::settings_running();
    let ctx = Ctx {
        owner: hwnd,
        saved: RefCell::new(initial.clone()),
        draft: RefCell::new(Draft::from_settings(&initial)),
        running,
        has444,
        has_host: store.config.host.as_deref().is_some_and(|h| !h.trim().is_empty()),
        config_path: store.path(),
        fingerprint: super::app::viewer_fingerprint(),
        default_dir: super::files::default_download_dir().display().to_string(),
        page: Cell::new(0),
        loading: Cell::new(false),
        error: Cell::new(None),
        restart: RefCell::new(Vec::new()),
        icons: RefCell::new(Vec::new()),
    };
    let r = unsafe {
        let Ok(hinst) = GetModuleHandleW(None) else { return };
        DialogBoxParamW(Some(HINSTANCE(hinst.0)), PCWSTR(IDD_SETTINGS as usize as *const u16), Some(hwnd), Some(dlg_proc), LPARAM(&ctx as *const Ctx as isize))
    };
    unsafe {
        for i in ctx.icons.borrow_mut().drain(..) {
            let _ = DestroyIcon(i);
        }
    }
    if r == -1 {
        eprintln!("settings window unavailable: {}", windows::core::Error::from_thread());
        return;
    }
    let restart = ctx.restart.into_inner();
    if !restart.is_empty() {
        let text = format!(
            "Restart Glide now to use the new {}?\n\nThe connection to the Mac closes and opens again. If you restart later, the changes apply then.",
            logic::join_words(&restart)
        );
        let t = wide(&text);
        if unsafe { MessageBoxW(Some(hwnd), PCWSTR(t.as_ptr()), TITLE, MB_YESNO | MB_ICONQUESTION) } == IDYES {
            // Keep this run's launch arguments (a Mac address or --listen on the command line wins
            // over the saved connection), so the restart reopens the same target.
            let args: Vec<String> = std::env::args().skip(1).collect();
            match super::setup::spawn_args(&super::setup::current_exe(), &logic::restart_args(&args)) {
                Ok(()) => unsafe {
                    let _ = DestroyWindow(hwnd);
                },
                Err(e) => {
                    eprintln!("settings: restart: {e}");
                    let t = wide(&e);
                    unsafe { MessageBoxW(Some(hwnd), PCWSTR(t.as_ptr()), TITLE, MB_OK | MB_ICONWARNING) };
                }
            }
        } else {
            eprintln!("settings: restart later for {}", logic::join_words(&restart));
        }
    }
}

fn init_common_controls() {
    let icc = INITCOMMONCONTROLSEX { dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES };
    unsafe {
        let _ = InitCommonControlsEx(&icc);
    }
}

/// The window's state, shared (`&Ctx`) with interior mutability: control calls made while
/// handling a message send notifications back into the dialog procedure.
struct Ctx {
    /// The viewer window (live changes are applied to it).
    owner: HWND,
    /// What is saved now (the last OK / Apply, or what the window opened with).
    saved: RefCell<Settings>,
    /// What isn't in a control: the paired list and the remembered displays. The controls hold
    /// the rest; `read` merges them.
    draft: RefCell<Draft>,
    running: Running,
    has444: bool,
    /// A Mac address is set (else this PC only listens, and "Let the Mac connect" is moot).
    has_host: bool,
    config_path: Option<PathBuf>,
    fingerprint: String,
    default_dir: String,
    page: Cell<usize>,
    /// Set while controls are filled (their change notifications are ignored).
    loading: Cell<bool>,
    /// The status line shows a validation error for this field.
    error: Cell<Option<Field>>,
    /// Saved changes that only a restart picks up.
    restart: RefCell<Vec<&'static str>>,
    icons: RefCell<Vec<HICON>>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe fn ctx_of(h: HWND) -> Option<&'static Ctx> {
    let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *const Ctx;
    p.as_ref()
}

unsafe fn item(h: HWND, id: i32) -> HWND {
    GetDlgItem(Some(h), id).unwrap_or_default()
}

unsafe fn send(w: HWND, msg: u32, wp: usize, lp: isize) -> isize {
    SendMessageW(w, msg, Some(WPARAM(wp)), Some(LPARAM(lp))).0
}

unsafe fn set_text(h: HWND, id: i32, s: &str) {
    let _ = SetDlgItemTextW(h, id, PCWSTR(wide(s).as_ptr()));
}

unsafe fn get_text(h: HWND, id: i32) -> String {
    let c = item(h, id);
    let n = GetWindowTextLengthW(c).max(0) as usize;
    let mut buf = vec![0u16; n + 1];
    let got = GetDlgItemTextW(h, id, &mut buf) as usize;
    String::from_utf16_lossy(&buf[..got.min(n)])
}

unsafe fn checked(h: HWND, id: i32) -> bool {
    IsDlgButtonChecked(h, id) == BST_CHECKED.0
}

unsafe fn check(h: HWND, id: i32, on: bool) {
    let _ = CheckDlgButton(h, id, if on { BST_CHECKED } else { BST_UNCHECKED });
}

unsafe fn enable(h: HWND, id: i32, on: bool) {
    if let Ok(c) = GetDlgItem(Some(h), id) {
        let _ = EnableWindow(c, on);
    }
}

unsafe fn show_item(h: HWND, id: i32, on: bool) {
    if let Ok(c) = GetDlgItem(Some(h), id) {
        let _ = ShowWindow(c, if on { SW_SHOW } else { SW_HIDE });
    }
}

/// Move the keyboard focus to control `id` the dialog way (edit text selected).
unsafe fn focus(h: HWND, id: i32) {
    let c = item(h, id);
    if !c.is_invalid() {
        send(h, WM_NEXTDLGCTL, c.0 as usize, 1);
    }
}

unsafe fn cue(h: HWND, id: i32, text: &str) {
    let t = wide(text);
    send(item(h, id), EM_SETCUEBANNER, 1, t.as_ptr() as isize);
}

fn confirm(owner: HWND, text: &str) -> bool {
    let t = wide(text);
    unsafe { MessageBoxW(Some(owner), PCWSTR(t.as_ptr()), TITLE, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES }
}

fn page_index(p: Page) -> usize {
    Page::ALL.iter().position(|x| *x == p).unwrap_or(0)
}

/// Which page control `id` is on (None: the list, the status line, the buttons).
fn page_of(id: i32) -> Option<usize> {
    let p = (id - PAGE_BASE).div_euclid(PAGE_SPAN);
    (id >= PAGE_BASE && (p as usize) < Page::ALL.len()).then_some(p as usize)
}

/// The control a validation error is about.
fn field_control(f: Field) -> i32 {
    match f {
        Field::DownloadDir => IDC_DIR,
        Field::MaxSize => IDC_MAX_SIZE,
        Field::MaxFiles => IDC_MAX_FILES,
        Field::ListenPort => IDC_PORT,
        Field::AllowedPeers => IDC_PEERS,
    }
}

/// Show page `p`: its group box and controls, nothing of the others.
unsafe fn show_page(h: HWND, ctx: &Ctx, p: usize) {
    ctx.page.set(p);
    send(item(h, IDC_PAGES), LB_SETCURSEL, p, 0);
    let _ = SendMessageW(h, WM_SETREDRAW, Some(WPARAM(0)), None);
    for i in 0..Page::ALL.len() as i32 {
        show_item(h, IDC_GROUP + i, i as usize == p);
    }
    let mut c = GetWindow(h, GW_CHILD).unwrap_or_default();
    while !c.is_invalid() {
        if let Some(cp) = page_of(GetDlgCtrlID(c)) {
            let _ = ShowWindow(c, if cp == p { SW_SHOW } else { SW_HIDE });
        }
        c = GetWindow(c, GW_HWNDNEXT).unwrap_or_default();
    }
    let _ = SendMessageW(h, WM_SETREDRAW, Some(WPARAM(1)), None);
    let _ = windows::Win32::Graphics::Gdi::RedrawWindow(
        Some(h),
        None,
        None,
        windows::Win32::Graphics::Gdi::RDW_ERASE | windows::Win32::Graphics::Gdi::RDW_INVALIDATE | windows::Win32::Graphics::Gdi::RDW_ALLCHILDREN,
    );
}

unsafe fn mode_index(m: Option<crate::protocol::Mode>) -> usize {
    logic::MODES.iter().position(|x| *x == m).unwrap_or(0)
}

/// Fill every control from `d`.
unsafe fn load(h: HWND, ctx: &Ctx, d: &Draft) {
    ctx.loading.set(true);
    *ctx.draft.borrow_mut() = d.clone();
    let v = &d.values;
    check(h, IDC_AUTOSTART, v.autostart);
    check(h, IDC_CONNECT_AT_SIGNIN, v.connect_at_signin);
    check(h, IDC_BAR_PINNED, v.bar_pinned);
    check(h, IDC_HUD, v.hud);
    send(item(h, IDC_MODE), CB_SETCURSEL, mode_index(v.mode), 0);
    check(h, IDC_CTRL_AS_CMD, v.ctrl_as_cmd);
    check(h, IDC_NATURAL, v.natural_scrolling);
    check(h, IDC_AUDIO, v.audio);
    check(h, IDC_MUTED, v.audio_muted);
    check(h, IDC_CLIPBOARD, v.clipboard);
    check(h, IDC_SECRETS, v.clipboard_sync_secrets);
    check(h, IDC_FILES, v.file_transfer);
    check(h, IDC_RECEIVE, v.file_receive);
    set_text(h, IDC_DIR, &d.download_dir);
    set_text(h, IDC_MAX_SIZE, &d.max_size_gb);
    set_text(h, IDC_MAX_FILES, &d.max_files);
    set_text(h, IDC_PORT, &d.listen_port);
    check(h, IDC_ACCEPT, v.accept_incoming || !ctx.has_host);
    set_text(h, IDC_PEERS, &d.allowed_peers);
    fill_paired(h, ctx);
    ctx.loading.set(false);
    sync(h, ctx);
}

/// The draft as the controls show it.
unsafe fn read(h: HWND, ctx: &Ctx) -> Draft {
    let mut d = ctx.draft.borrow().clone();
    let v = &mut d.values;
    v.autostart = checked(h, IDC_AUTOSTART);
    v.connect_at_signin = checked(h, IDC_CONNECT_AT_SIGNIN);
    v.bar_pinned = checked(h, IDC_BAR_PINNED);
    v.hud = checked(h, IDC_HUD);
    let sel = send(item(h, IDC_MODE), CB_GETCURSEL, 0, 0);
    v.mode = logic::MODES.get(sel.max(0) as usize).copied().flatten();
    v.ctrl_as_cmd = checked(h, IDC_CTRL_AS_CMD);
    v.natural_scrolling = checked(h, IDC_NATURAL);
    v.audio = checked(h, IDC_AUDIO);
    v.audio_muted = checked(h, IDC_MUTED);
    v.clipboard = checked(h, IDC_CLIPBOARD);
    v.clipboard_sync_secrets = checked(h, IDC_SECRETS);
    v.file_transfer = checked(h, IDC_FILES);
    v.file_receive = checked(h, IDC_RECEIVE);
    // Listen-only (no Mac address): the box is always on and disabled; keep the saved value.
    if ctx.has_host {
        v.accept_incoming = checked(h, IDC_ACCEPT);
    }
    d.download_dir = get_text(h, IDC_DIR).trim().to_string();
    d.max_size_gb = get_text(h, IDC_MAX_SIZE);
    d.max_files = get_text(h, IDC_MAX_FILES);
    d.listen_port = get_text(h, IDC_PORT);
    d.allowed_peers = get_text(h, IDC_PEERS);
    d
}

/// Enable what depends on other controls, refresh the texts that describe state, and enable
/// Apply when something differs from what is saved.
unsafe fn sync(h: HWND, ctx: &Ctx) {
    if ctx.loading.get() {
        return;
    }
    let d = read(h, ctx);
    let v = &d.values;
    enable(h, IDC_CONNECT_AT_SIGNIN, v.autostart);
    enable(h, IDC_SIGNIN_NOTE, v.autostart);
    // A per-machine (MSI) install manages sign-in start itself.
    enable(h, IDC_AUTOSTART, !super::setup::deployed());
    set_text(h, IDC_MODE_HELP, &logic::mode_help(v.mode, ctx.has444));
    let saved_displays = ctx.saved.borrow().remembered_displays;
    enable(h, IDC_FORGET_DISPLAYS, v.remembered_displays > 0);
    set_text(
        h,
        IDC_DISPLAYS_NOTE,
        &match (saved_displays, v.remembered_displays) {
            (0, _) => "None remembered yet.".to_string(),
            (_, 0) => "Forgotten when you click OK or Apply.".to_string(),
            (n, _) => format!("{n} remembered."),
        },
    );
    enable(h, IDC_MUTED, v.audio);
    set_text(
        h,
        IDC_AUDIO_NOTE,
        if v.audio != ctx.saved.borrow().audio {
            "Turning the Mac's sound on or off takes effect when Glide restarts."
        } else if !ctx.running.audio && v.audio {
            "Glide was started without sound (--no-audio): it plays when started normally."
        } else {
            ""
        },
    );
    enable(h, IDC_SECRETS, v.clipboard);
    enable(h, IDC_SECRETS_WARN, v.clipboard);
    for id in FILE_DETAILS {
        enable(h, id, v.file_transfer);
    }
    enable(h, IDC_ACCEPT, ctx.has_host);
    let sel = selected_paired(h, ctx).is_some();
    enable(h, IDC_UNPAIR, sel);
    enable(h, IDC_OPEN_CONFIG, ctx.config_path.is_some());
    let dirty = d != Draft::from_settings(&ctx.saved.borrow());
    enable(h, IDC_APPLY, dirty);
    // A control that just got disabled can't keep the keyboard focus.
    let f = GetFocus();
    if !f.is_invalid() && !IsWindowEnabled(f).as_bool() {
        let _ = SetFocus(Some(item(h, IDC_PAGES)));
    }
}

unsafe fn set_status(h: HWND, ctx: &Ctx, text: &str, error: Option<Field>) {
    ctx.error.set(error);
    set_text(h, IDC_STATUS, text);
}

// ------------------------------------------------------------------ paired Macs

unsafe fn setup_paired(h: HWND) {
    let lv = item(h, IDC_PAIRED);
    let ex = (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER) as isize;
    send(lv, LVM_SETEXTENDEDLISTVIEWSTYLE, ex as usize, ex);
    let mut rc = RECT::default();
    let _ = GetClientRect(lv, &mut rc);
    let dpi = GetDpiForWindow(h).max(96);
    let width = (rc.right - rc.left - GetSystemMetricsForDpi(SM_CXVSCROLL, dpi)).max(120);
    let cols: [(&str, i32); 3] = [("Mac", 32), ("Address", 44), ("Paired", 24)];
    for (i, (title, pct)) in cols.iter().enumerate() {
        let mut t = wide(title);
        let col = LVCOLUMNW {
            mask: LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM | LVCF_FMT,
            fmt: LVCFMT_LEFT,
            cx: width * pct / 100,
            pszText: PWSTR(t.as_mut_ptr()),
            iSubItem: i as i32,
            ..Default::default()
        };
        send(lv, LVM_INSERTCOLUMNW, i, &col as *const LVCOLUMNW as isize);
    }
}

fn paired_rows(ctx: &Ctx) -> Vec<PairedRow> {
    let c = super::app::store_snapshot().config;
    logic::paired_rows(&c, &ctx.draft.borrow().values.paired)
}

unsafe fn fill_paired(h: HWND, ctx: &Ctx) {
    let lv = item(h, IDC_PAIRED);
    send(lv, LVM_DELETEALLITEMS, 0, 0);
    let rows = paired_rows(ctx);
    if rows.is_empty() {
        let mut t = wide("No Mac paired yet");
        let it = LVITEMW { mask: LVIF_TEXT | LVIF_PARAM, pszText: PWSTR(t.as_mut_ptr()), lParam: LPARAM(-1), ..Default::default() };
        send(lv, LVM_INSERTITEMW, 0, &it as *const LVITEMW as isize);
    }
    for (i, r) in rows.iter().enumerate() {
        let mut name = wide(&r.name);
        let it = LVITEMW { mask: LVIF_TEXT | LVIF_PARAM, iItem: i as i32, pszText: PWSTR(name.as_mut_ptr()), lParam: LPARAM(i as isize), ..Default::default() };
        let idx = send(lv, LVM_INSERTITEMW, 0, &it as *const LVITEMW as isize);
        if idx < 0 {
            continue;
        }
        for (sub, text) in [(1, &r.target), (2, &r.paired)] {
            let mut t = wide(text);
            let si = LVITEMW { iSubItem: sub, pszText: PWSTR(t.as_mut_ptr()), ..Default::default() };
            send(lv, LVM_SETITEMTEXTW, idx as usize, &si as *const LVITEMW as isize);
        }
    }
}

unsafe fn selected_paired(h: HWND, ctx: &Ctx) -> Option<PairedRow> {
    let lv = item(h, IDC_PAIRED);
    let idx = send(lv, LVM_GETNEXTITEM, usize::MAX, LVNI_SELECTED as isize);
    if idx < 0 {
        return None;
    }
    let mut it = LVITEMW { mask: LVIF_PARAM, iItem: idx as i32, ..Default::default() };
    if send(lv, LVM_GETITEMW, 0, &mut it as *mut LVITEMW as isize) == 0 || it.lParam.0 < 0 {
        return None;
    }
    paired_rows(ctx).get(it.lParam.0 as usize).cloned()
}

unsafe fn do_unpair(h: HWND, ctx: &Ctx) {
    let Some(r) = selected_paired(h, ctx) else { return };
    let mut text = format!(
        "Unpair “{}” ({})?\n\nThis PC stops trusting its key when you click OK or Apply. To connect again, both screens show a code to confirm.",
        r.name, r.target
    );
    if ctx.running.pins.contains(&r.key) {
        text.push_str("\n\nIt is the Mac Glide is using now: Glide offers to restart when you close this window.");
    }
    if !confirm(h, &text) {
        return;
    }
    // Keep what the other controls show; only the list changes.
    let d = read(h, ctx);
    *ctx.draft.borrow_mut() = d;
    ctx.draft.borrow_mut().values.paired.retain(|k| *k != r.key);
    fill_paired(h, ctx);
    sync(h, ctx);
}

// ------------------------------------------------------------------ buttons

/// IFileOpenDialog in folder mode. None = cancelled or failed (the failure is logged).
unsafe fn pick_folder(h: HWND, start: &str) -> Option<String> {
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::Shell::*;
    let run = || -> windows::core::Result<Option<String>> {
        // The UI thread is (or becomes) an STA; S_FALSE / RPC_E_CHANGED_MODE are fine here.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let dlg: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
        dlg.SetOptions(dlg.GetOptions()? | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST)?;
        dlg.SetTitle(w!("Save received files in"))?;
        if !start.is_empty() {
            let p = wide(start);
            if let Ok(si) = SHCreateItemFromParsingName::<_, _, IShellItem>(PCWSTR(p.as_ptr()), None) {
                let _ = dlg.SetFolder(&si);
            }
        }
        if let Err(e) = dlg.Show(Some(h)) {
            // ERROR_CANCELLED
            return if e.code() == windows::core::HRESULT::from_win32(1223) { Ok(None) } else { Err(e) };
        }
        let p = dlg.GetResult()?.GetDisplayName(SIGDN_FILESYSPATH)?;
        let s = p.to_string().unwrap_or_default();
        CoTaskMemFree(Some(p.0 as *const _));
        Ok(Some(s).filter(|s| !s.is_empty()))
    };
    run().unwrap_or_else(|e| {
        eprintln!("settings: folder picker failed: {e}");
        None
    })
}

unsafe fn do_browse(h: HWND, ctx: &Ctx) {
    let cur = get_text(h, IDC_DIR);
    let start = if cur.trim().is_empty() { ctx.default_dir.clone() } else { cur };
    if let Some(dir) = pick_folder(h, &start) {
        set_text(h, IDC_DIR, &dir);
    }
}

/// Put `text` on the Windows clipboard (it then syncs to the Mac like anything copied).
unsafe fn copy_text(h: HWND, text: &str) -> bool {
    const CF_UNICODETEXT: u32 = 13;
    let t: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    if OpenClipboard(Some(h)).is_err() {
        return false;
    }
    let mut ok = EmptyClipboard().is_ok();
    if ok {
        ok = false;
        if let Ok(g) = GlobalAlloc(GMEM_MOVEABLE, t.len() * 2) {
            let p = GlobalLock(g) as *mut u16;
            if !p.is_null() {
                std::ptr::copy_nonoverlapping(t.as_ptr(), p, t.len());
                let _ = GlobalUnlock(g);
                ok = SetClipboardData(CF_UNICODETEXT, Some(HANDLE(g.0))).is_ok();
            }
            if !ok {
                let _ = GlobalFree(Some(g));
            }
        }
    }
    let _ = CloseClipboard();
    ok
}

unsafe fn do_reset(h: HWND, ctx: &Ctx) {
    if !confirm(h, "Reset the settings on every page to their defaults?\n\nSaved connections, pairings, allowed addresses and start at sign-in stay as they are. Nothing is saved until you click OK or Apply.") {
        return;
    }
    let cur = read(h, ctx);
    load(h, ctx, &Draft::from_settings(&cur.values.reset()));
    set_status(h, ctx, "Defaults restored. Click OK or Apply to save them.", None);
}

/// OK / Apply: validate, save, apply. False when something is wrong (shown in the window).
unsafe fn commit(h: HWND, ctx: &Ctx) -> bool {
    let d = read(h, ctx);
    let mut after = match logic::validate(&d) {
        Ok(s) => s,
        Err((field, msg)) => {
            show_page(h, ctx, page_index(field.page()));
            set_status(h, ctx, &msg, Some(field));
            focus(h, field_control(field));
            return false;
        }
    };
    let before = ctx.saved.borrow().clone();
    let mut ch = logic::diff(&before, &after, &ctx.running);
    if !ch.any {
        set_status(h, ctx, "", None);
        return true;
    }
    let mut note = String::new();
    if let Some(on) = ch.autostart {
        if let Err(e) = super::setup::set_autostart(on, &super::setup::current_exe()) {
            eprintln!("settings: start at sign-in: {e}");
            after.autostart = before.autostart;
            note = format!(" Start at sign-in wasn't changed: {e}.");
            ch = logic::diff(&before, &after, &ctx.running);
        }
    }
    super::app::update_store(|c| logic::apply(c, &before, &after));
    // `apply` may have moved pins (a listen-port change re-keys listen-mode pairings): show the
    // pairings as saved, or the moved one would drop out of the list until Settings reopens.
    after.paired = super::app::store_snapshot().config.pinned_hosts.keys().cloned().collect();
    super::app::apply_live_settings(ctx.owner, &ch.live);
    eprintln!("settings: saved (live {:?}, restart {:?})", ch.live, ch.restart);
    {
        let mut r = ctx.restart.borrow_mut();
        for w in &ch.restart {
            if !r.contains(w) {
                r.push(w);
            }
        }
    }
    *ctx.saved.borrow_mut() = after.clone();
    load(h, ctx, &Draft::from_settings(&after));
    let pending = ctx.restart.borrow().clone();
    let text = if pending.is_empty() {
        format!("Saved.{note}")
    } else {
        format!("Saved. The new {} take effect when Glide restarts (it offers to when you close this window).{note}", logic::join_words(&pending))
    };
    set_status(h, ctx, &text, None);
    true
}

unsafe fn set_icons(h: HWND, ctx: &Ctx) {
    let dpi = GetDpiForWindow(h).max(96);
    let big = GetSystemMetricsForDpi(SM_CXICON, dpi);
    let small = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
    if let (Some(ib), Some(is)) = (super::prompt::app_icon(big), super::prompt::app_icon(small)) {
        SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(ib.0 as isize)));
        SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(is.0 as isize)));
        ctx.icons.borrow_mut().extend([ib, is]);
    }
}

/// `GLIDE_SETTINGS_DUMP`: print the draft, capture every page, close.
unsafe fn dump(h: HWND, ctx: &Ctx, path: &str) {
    eprint!("{}", logic::to_text(&read(h, ctx), ctx.has444));
    let stem = path.strip_suffix(".bmp").unwrap_or(path);
    for p in 0..Page::ALL.len() {
        show_page(h, ctx, p);
        let _ = UpdateWindow(h);
        let file = format!("{stem}-{}.bmp", p + 1);
        match super::prompt::dump_window(h, &file) {
            Ok((w, hh)) => eprintln!("settings: dumped {w}x{hh} page “{}” to {file}", Page::ALL[p].title()),
            Err(e) => eprintln!("settings: dump failed: {e}"),
        }
    }
    let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(IDCANCEL.0 as usize), LPARAM(0));
}

unsafe extern "system" fn dlg_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &*(lp.0 as *const Ctx);
            let _ = SetWindowTextW(h, TITLE);
            set_icons(h, ctx);
            // Texts with characters this ASCII-only .rc can't hold.
            set_text(h, IDC_BROWSE, "&Browse…");
            set_text(h, IDC_OPEN_CONFIG, "&Open config file…");
            set_text(h, IDC_RESET, "&Reset to defaults…");
            for (i, p) in Page::ALL.iter().enumerate() {
                let t = wide(p.title());
                send(item(h, IDC_PAGES), LB_ADDSTRING, 0, t.as_ptr() as isize);
                set_text(h, IDC_GROUP + i as i32, &p.title().replace('&', "&&"));
            }
            let combo = item(h, IDC_MODE);
            for m in logic::MODES {
                let t = wide(logic::mode_label(m));
                send(combo, CB_ADDSTRING, 0, t.as_ptr() as isize);
            }
            cue(h, IDC_DIR, &format!("{} (default)", ctx.default_dir));
            cue(h, IDC_PEERS, "192.168.1.50 or 192.168.1.0/24");
            send(item(h, IDC_PORT), EM_LIMITTEXT, 5, 0);
            send(item(h, IDC_MAX_FILES), EM_LIMITTEXT, 7, 0);
            send(item(h, IDC_MAX_SIZE), EM_LIMITTEXT, 10, 0);
            set_text(h, IDC_FINGERPRINT, if ctx.fingerprint.is_empty() { "(unknown)" } else { &ctx.fingerprint });
            enable(h, IDC_COPY, !ctx.fingerprint.is_empty());
            set_text(h, IDC_CONFIG_PATH, &ctx.config_path.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "Not saved (no APPDATA folder)".into()));
            set_text(
                h,
                IDC_ACCEPT,
                if ctx.has_host {
                    "Let the &Mac connect to this PC (the current connection)"
                } else {
                    "Let the &Mac connect to this PC (always, until you enter its address)"
                },
            );
            setup_paired(h);
            let d = ctx.draft.borrow().clone();
            load(h, ctx, &d);
            show_page(h, ctx, 0);
            set_status(h, ctx, "", None);
            let _ = SetForegroundWindow(h);
            if crate::util::test_hook("GLIDE_SETTINGS_DUMP").is_some() {
                SetTimer(Some(h), HOOK_TIMER, 500, None);
            }
            let _ = SetFocus(Some(item(h, IDC_PAGES)));
            0
        }
        WM_TIMER if wp.0 == HOOK_TIMER => {
            let _ = KillTimer(Some(h), HOOK_TIMER);
            if let (Some(ctx), Some(p)) = (ctx_of(h), crate::util::test_hook("GLIDE_SETTINGS_DUMP")) {
                dump(h, ctx, &p);
            }
            1
        }
        WM_CTLCOLORSTATIC => {
            let Some(ctx) = ctx_of(h) else { return 0 };
            let c = HWND(lp.0 as *mut _);
            let red = (c == item(h, IDC_STATUS) && ctx.error.get().is_some())
                || (c == item(h, IDC_SECRETS_WARN) && checked(h, IDC_SECRETS) && checked(h, IDC_CLIPBOARD));
            if red {
                let dc = HDC(wp.0 as *mut _);
                SetTextColor(dc, RED);
                SetBkMode(dc, TRANSPARENT);
                return GetSysColorBrush(COLOR_BTNFACE).0 as isize;
            }
            0
        }
        WM_NOTIFY => {
            let Some(ctx) = ctx_of(h) else { return 0 };
            let hdr = &*(lp.0 as *const NMHDR);
            if hdr.idFrom == IDC_PAIRED as usize && hdr.code == LVN_ITEMCHANGED {
                sync(h, ctx);
            }
            0
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            let code = ((wp.0 >> 16) & 0xFFFF) as u32;
            let Some(ctx) = ctx_of(h) else { return 0 };
            match id {
                IDC_PAGES if code == LBN_SELCHANGE => {
                    let sel = send(item(h, IDC_PAGES), LB_GETCURSEL, 0, 0);
                    if sel >= 0 {
                        show_page(h, ctx, sel as usize);
                    }
                }
                IDC_MODE if code == CBN_SELCHANGE => sync(h, ctx),
                IDC_DIR | IDC_MAX_SIZE | IDC_MAX_FILES | IDC_PORT | IDC_PEERS if code == EN_CHANGE => {
                    if !ctx.loading.get() {
                        // The error was about this field: typing clears it.
                        if ctx.error.get().is_some_and(|f| field_control(f) == id) {
                            set_status(h, ctx, "", None);
                        }
                        sync(h, ctx);
                    }
                }
                IDC_BROWSE => do_browse(h, ctx),
                IDC_DIR_DEFAULT => {
                    set_text(h, IDC_DIR, "");
                    focus(h, IDC_DIR);
                }
                IDC_FORGET_DISPLAYS => {
                    let d = read(h, ctx);
                    *ctx.draft.borrow_mut() = d;
                    ctx.draft.borrow_mut().values.remembered_displays = 0;
                    sync(h, ctx);
                }
                IDC_UNPAIR => do_unpair(h, ctx),
                IDC_COPY => {
                    let ok = copy_text(h, &ctx.fingerprint);
                    set_status(h, ctx, if ok { "Key fingerprint copied." } else { "Couldn't open the clipboard. Try again." }, None);
                }
                IDC_OPEN_CONFIG => {
                    if let Some(p) = &ctx.config_path {
                        super::tray::open_in_editor(p);
                    }
                }
                IDC_RESET => do_reset(h, ctx),
                IDC_APPLY => {
                    commit(h, ctx);
                }
                x if x == IDOK.0 => {
                    if commit(h, ctx) {
                        let _ = EndDialog(h, IDOK.0 as isize);
                    }
                }
                x if x == IDCANCEL.0 => {
                    let _ = EndDialog(h, IDCANCEL.0 as isize);
                }
                _ if code == BN_CLICKED && page_of(id).is_some() => {
                    sync(h, ctx);
                    if id == IDC_SECRETS || id == IDC_CLIPBOARD {
                        // Repaint the warning in its new color.
                        let _ = windows::Win32::Graphics::Gdi::InvalidateRect(Some(item(h, IDC_SECRETS_WARN)), None, true);
                    }
                }
                _ => return 0,
            }
            1
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controls_map_to_their_page() {
        assert_eq!(page_of(IDC_AUTOSTART), Some(page_index(Page::General)));
        assert_eq!(page_of(IDC_MODE), Some(page_index(Page::Picture)));
        assert_eq!(page_of(IDC_CTRL_AS_CMD), Some(page_index(Page::Input)));
        assert_eq!(page_of(IDC_MUTED), Some(page_index(Page::Audio)));
        assert_eq!(page_of(IDC_SECRETS_WARN), Some(page_index(Page::Clipboard)));
        assert_eq!(page_of(IDC_MAX_FILES), Some(page_index(Page::Files)));
        assert_eq!(page_of(IDC_COPY), Some(page_index(Page::Network)));
        assert_eq!(page_of(IDC_RESET), Some(page_index(Page::Advanced)));
        assert_eq!(page_of(IDC_PAGES), None);
        assert_eq!(page_of(IDC_STATUS), None);
        assert_eq!(page_of(IDC_APPLY), None);
        assert_eq!(page_of(IDOK.0), None);
        for f in [Field::DownloadDir, Field::MaxSize, Field::MaxFiles, Field::ListenPort, Field::AllowedPeers] {
            assert_eq!(page_of(field_control(f)), Some(page_index(f.page())), "{f:?}");
        }
    }
}
