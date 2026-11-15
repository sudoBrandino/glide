//! Connections window (tray / Glide menu → Connections…): the saved Macs, with Connect, Add,
//! Edit, Duplicate, Remove and Unpair. The model and its rules live in `crate::connections`;
//! this is the Win32 UI on top of it.
//!
//! Switching to another connection saves it as the active one and restarts the viewer onto it
//! (the same `--after-setup` restart the Set up dialog uses): the session thread resolves its
//! target once, at startup.
//!
//! - `IDD_CONNS` (res/glide.rc): a search box, a report list view (grouped by the connection's
//!   group when the visible rows span more than one), the actions, and a status line about the
//!   selection. Connect is IDOK (Enter, double-click); Delete removes, F2 edits.
//! - `IDD_CONN_EDIT`: Add / Edit one connection (name, address + Test, group, accept incoming,
//!   favorite), validated with `logic::validate`.
//!
//! Anything that needs a restart (Connect, removing / unpairing / retargeting the active
//! connection) happens after `DialogBoxParamW` returns, never inside the modal loop.
//!
//! Test hook (`test-hooks` builds only, see `util::test_hook`): `GLIDE_CONNS_DUMP=x.bmp` saves a
//! capture of the window after ~0.5 s and closes it.

use crate::connections::{self as logic, Draft, Field, Row};
use std::cell::{Cell, RefCell};
use std::time::{Duration, SystemTime};
use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{GetSysColorBrush, InvalidateRect, SetBkMode, SetTextColor, COLOR_BTNFACE, HDC, TRANSPARENT};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::*;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, GetFocus, IsWindowEnabled, SetFocus, VK_DELETE, VK_F2};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_CONNS: u16 = 104;
const IDC_CN_SEARCH: i32 = 1300;
const IDC_CN_LIST: i32 = 1301;
const IDC_CN_ADD: i32 = 1302;
const IDC_CN_EDIT: i32 = 1303;
const IDC_CN_DUPLICATE: i32 = 1304;
const IDC_CN_REMOVE: i32 = 1305;
const IDC_CN_UNPAIR: i32 = 1306;
const IDC_CN_STATUS: i32 = 1307;

const IDD_CONN_EDIT: u16 = 105;
const IDC_CE_NAME: i32 = 1400;
const IDC_CE_ADDR: i32 = 1401;
const IDC_CE_TEST: i32 = 1402;
const IDC_CE_TEST_RESULT: i32 = 1403;
const IDC_CE_GROUP: i32 = 1404;
const IDC_CE_ACCEPT: i32 = 1405;
const IDC_CE_FAVORITE: i32 = 1406;
const IDC_CE_ERROR: i32 = 1407;

/// Background → edit form: Box<(generation, Result<text, text>, address)> of a Test.
const WM_CE_TESTED: u32 = WM_APP + 1;
const HOOK_TIMER: usize = 1;

const TITLE: PCWSTR = w!("Glide — Connections");
const RESTART_NOTE: &str = "Glide will reconnect when you close this window.";

/// Make `id` the active connection; restart the viewer onto it if the target changed.
/// Errors are shown to the user.
pub fn switch_to(hwnd: HWND, id: &str) {
    let mut res = Ok(false);
    super::app::update_store(|c| res = logic::activate(c, id).map(|changed| changed || !is_running(c, id)));
    match res {
        Ok(true) => restart(hwnd),
        Ok(false) => {}
        Err(e) => error_box(Some(hwnd), &e),
    }
}

/// Whether this viewer is running with connection `id`'s target. It may not be even when `id` is
/// the active connection: a host or `--listen` on the command line overrides it for this run.
fn is_running(c: &crate::config::Config, id: &str) -> bool {
    logic::get(c, id).is_some_and(|s| s.pin_key(c.listen_port) == super::app::running_pin_target())
}

/// Connect makes sense for this row: a supported connection this viewer isn't already using.
fn can_connect(r: &Row) -> bool {
    r.supported && !(r.active && is_running(&snapshot(), &r.id))
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
    init_common_controls();
    let ctx = Ctx {
        rows: RefCell::new(Vec::new()),
        refreshing: Cell::new(false),
        restart: Cell::new(false),
        connect: RefCell::new(None),
        icons: RefCell::new(Vec::new()),
    };
    let r = unsafe {
        let Ok(hinst) = GetModuleHandleW(None) else { return };
        DialogBoxParamW(Some(HINSTANCE(hinst.0)), PCWSTR(IDD_CONNS as usize as *const u16), Some(hwnd), Some(conns_proc), LPARAM(&ctx as *const Ctx as isize))
    };
    unsafe {
        for i in ctx.icons.borrow_mut().drain(..) {
            let _ = DestroyIcon(i);
        }
    }
    if r == -1 {
        eprintln!("connections window unavailable: {}", windows::core::Error::from_thread());
        return;
    }
    let connect = ctx.connect.borrow_mut().take();
    match (connect, ctx.restart.get()) {
        (Some(id), false) => switch_to(hwnd, &id),
        (Some(id), true) => {
            // Something else already needs a restart: activate, then restart either way.
            let mut res = Ok(false);
            super::app::update_store(|c| res = logic::activate(c, &id));
            if let Err(e) = res {
                error_box(Some(hwnd), &e);
            }
            restart(hwnd);
        }
        (None, true) => restart(hwnd),
        (None, false) => {}
    }
}

fn init_common_controls() {
    let icc = INITCOMMONCONTROLSEX { dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32, dwICC: ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES };
    unsafe {
        let _ = InitCommonControlsEx(&icc);
    }
}

/// The Connections window's state. Shared (`&Ctx`) with interior mutability: list view calls made
/// while handling a message send notifications back into the dialog procedure.
struct Ctx {
    /// The rows shown, in list order; each item's lParam is its index here.
    rows: RefCell<Vec<Row>>,
    /// Set while the list is rebuilt (its LVN_ITEMCHANGED storm is ignored).
    refreshing: Cell<bool>,
    /// The active connection's target changed: restart the viewer after the window closes.
    restart: Cell<bool>,
    /// Connect was chosen: switch to this id after the window closes.
    connect: RefCell<Option<String>>,
    icons: RefCell<Vec<HICON>>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn snapshot() -> crate::config::Config {
    super::app::store_snapshot().config
}

unsafe fn ctx_of<T>(h: HWND) -> Option<&'static T> {
    let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *const T;
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
    let mut buf = [0u16; 512];
    let n = GetDlgItemTextW(h, id, &mut buf) as usize;
    String::from_utf16_lossy(&buf[..n.min(buf.len())])
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

unsafe fn show(h: HWND, id: i32, on: bool) {
    if let Ok(c) = GetDlgItem(Some(h), id) {
        let _ = ShowWindow(c, if on { SW_SHOW } else { SW_HIDE });
    }
}

/// Move the keyboard focus to control `id` the dialog way (default button, edit text selected).
unsafe fn focus(h: HWND, id: i32) {
    let c = item(h, id);
    if !c.is_invalid() {
        send(h, WM_NEXTDLGCTL, c.0 as usize, 1);
    }
}

unsafe fn cue(h: HWND, id: i32, text: &str, when_focused: bool) {
    let t = wide(text);
    send(item(h, id), EM_SETCUEBANNER, when_focused as usize, t.as_ptr() as isize);
}

fn confirm(owner: HWND, text: &str) -> bool {
    let t = wide(text);
    unsafe { MessageBoxW(Some(owner), PCWSTR(t.as_ptr()), TITLE, MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES }
}

/// Post `v` to a window, or drop it if the window is gone.
fn post_box<T>(h: isize, msg: u32, v: T) {
    let p = Box::into_raw(Box::new(v));
    unsafe {
        if PostMessageW(Some(HWND(h as *mut _)), msg, WPARAM(0), LPARAM(p as isize)).is_err() {
            drop(Box::from_raw(p));
        }
    }
}

/// "Last used 2 hours ago" / "Never used".
fn last_used_phrase(r: &Row) -> String {
    match r.last_used.as_str() {
        "Never" => "Never used".into(),
        // A date ("2026-11-02"; `relative_time` for older uses), not "5 days ago" (also 10 chars).
        s if s.len() == 10 && s.as_bytes()[4] == b'-' && s.as_bytes()[7] == b'-' => format!("Last used on {s}"),
        s => {
            let mut c = s.chars();
            let lower = c.next().map(|f| f.to_lowercase().chain(c).collect::<String>()).unwrap_or_default();
            format!("Last used {lower}")
        }
    }
}

/// The list's first column: "★ Studio Mac (current)".
fn name_label(r: &Row) -> String {
    format!("{}{}{}", if r.favorite { "★ " } else { "" }, r.name, if r.active { " (current)" } else { "" })
}

// ---------------------------------------------------------------------------------------------
// Connections window

unsafe fn list(h: HWND) -> HWND {
    item(h, IDC_CN_LIST)
}

unsafe fn setup_list(h: HWND) {
    let lv = list(h);
    let ex = (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER) as isize;
    send(lv, LVM_SETEXTENDEDLISTVIEWSTYLE, ex as usize, ex);
    let mut rc = RECT::default();
    let _ = GetClientRect(lv, &mut rc);
    let dpi = GetDpiForWindow(h).max(96);
    // Leave room for a vertical scroll bar so a long list never needs a horizontal one.
    let width = (rc.right - rc.left - GetSystemMetricsForDpi(SM_CXVSCROLL, dpi)).max(200);
    let cols: [(&str, i32); 5] = [("Name", 28), ("Address", 22), ("Group", 14), ("Status", 22), ("Last used", 14)];
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

/// The row whose item is selected in the list.
unsafe fn selected(h: HWND, ctx: &Ctx) -> Option<Row> {
    let lv = list(h);
    let idx = send(lv, LVM_GETNEXTITEM, usize::MAX, LVNI_SELECTED as isize);
    if idx < 0 {
        return None;
    }
    let mut it = LVITEMW { mask: LVIF_PARAM, iItem: idx as i32, ..Default::default() };
    if send(lv, LVM_GETITEMW, 0, &mut it as *mut LVITEMW as isize) == 0 {
        return None;
    }
    ctx.rows.borrow().get(it.lParam.0 as usize).cloned()
}

/// Rebuild the list from the live config and the search text. Selects `prefer` if it is shown,
/// else the active connection, else the first row.
unsafe fn refresh(h: HWND, ctx: &Ctx, prefer: Option<String>) {
    let c = snapshot();
    let filter = get_text(h, IDC_CN_SEARCH);
    let rows = logic::rows(&c, &filter, SystemTime::now());
    *ctx.rows.borrow_mut() = rows.clone();
    let lv = list(h);
    ctx.refreshing.set(true);
    let _ = SendMessageW(lv, WM_SETREDRAW, Some(WPARAM(0)), None);
    send(lv, LVM_DELETEALLITEMS, 0, 0);
    send(lv, LVM_REMOVEALLGROUPS, 0, 0);

    // Groups in row order (ungrouped first, then A→Z: the order `rows` sorts by).
    let mut groups: Vec<String> = Vec::new();
    for r in &rows {
        if !groups.iter().any(|g| g.eq_ignore_ascii_case(&r.group)) {
            groups.push(r.group.clone());
        }
    }
    let grouped = groups.len() > 1;
    send(lv, LVM_ENABLEGROUPVIEW, grouped as usize, 0);
    if grouped {
        for (i, g) in groups.iter().enumerate() {
            let mut t = wide(if g.is_empty() { "Ungrouped" } else { g });
            let lg = LVGROUP {
                cbSize: std::mem::size_of::<LVGROUP>() as u32,
                mask: LVGF_HEADER | LVGF_GROUPID | LVGF_STATE,
                pszHeader: PWSTR(t.as_mut_ptr()),
                iGroupId: i as i32 + 1,
                stateMask: LVGS_COLLAPSIBLE,
                state: LVGS_COLLAPSIBLE,
                ..Default::default()
            };
            send(lv, LVM_INSERTGROUP, usize::MAX, &lg as *const LVGROUP as isize);
        }
    }

    for (i, r) in rows.iter().enumerate() {
        let mut name = wide(&name_label(r));
        let gid = groups.iter().position(|g| g.eq_ignore_ascii_case(&r.group)).map_or(0, |p| p as i32 + 1);
        let it = LVITEMW {
            mask: if grouped { LVIF_TEXT | LVIF_PARAM | LVIF_GROUPID } else { LVIF_TEXT | LVIF_PARAM },
            iItem: i as i32,
            pszText: PWSTR(name.as_mut_ptr()),
            lParam: LPARAM(i as isize),
            iGroupId: gid,
            ..Default::default()
        };
        let idx = send(lv, LVM_INSERTITEMW, 0, &it as *const LVITEMW as isize);
        if idx < 0 {
            continue;
        }
        for (sub, text) in [(1, &r.address), (2, &r.group), (3, &r.status), (4, &r.last_used)] {
            let mut t = wide(text);
            let si = LVITEMW { iSubItem: sub, pszText: PWSTR(t.as_mut_ptr()), ..Default::default() };
            send(lv, LVM_SETITEMTEXTW, idx as usize, &si as *const LVITEMW as isize);
        }
    }

    let want = prefer
        .and_then(|id| rows.iter().position(|r| r.id == id))
        .or_else(|| rows.iter().position(|r| r.active))
        .or(if rows.is_empty() { None } else { Some(0) });
    if let Some(i) = want {
        let st = LIST_VIEW_ITEM_STATE_FLAGS(LVIS_SELECTED.0 | LVIS_FOCUSED.0);
        let it = LVITEMW { stateMask: st, state: st, ..Default::default() };
        send(lv, LVM_SETITEMSTATE, i, &it as *const LVITEMW as isize);
        send(lv, LVM_ENSUREVISIBLE, i, 0);
    }
    let _ = SendMessageW(lv, WM_SETREDRAW, Some(WPARAM(1)), None);
    let _ = InvalidateRect(Some(lv), None, true);
    ctx.refreshing.set(false);
    update_selection(h, ctx);
}

/// Enable the buttons and describe the selection in the status line.
unsafe fn update_selection(h: HWND, ctx: &Ctx) {
    let sel = selected(h, ctx);
    let any = sel.is_some();
    enable(h, IDOK.0, sel.as_ref().is_some_and(can_connect));
    enable(h, IDC_CN_EDIT, any);
    enable(h, IDC_CN_DUPLICATE, any);
    enable(h, IDC_CN_REMOVE, any);
    enable(h, IDC_CN_UNPAIR, sel.as_ref().is_some_and(|r| r.paired));

    let total = snapshot().connections.len();
    let shown = ctx.rows.borrow().len();
    let mut text = match &sel {
        _ if total == 0 => "No saved connections yet. Click Add… to add your Mac.".to_string(),
        _ if shown == 0 => format!("No connection matches “{}”.", get_text(h, IDC_CN_SEARCH).trim()),
        None => format!("{total} saved connection{}. Select one to connect to it, edit or remove it.", if total == 1 { "" } else { "s" }),
        Some(r) => {
            let mut parts = vec![r.name.clone(), r.address.clone(), r.status.clone(), last_used_phrase(r)];
            if r.active {
                parts.push("Current connection".into());
            }
            parts.join(" · ")
        }
    };
    if ctx.restart.get() {
        text.push('\n');
        text.push_str(RESTART_NOTE);
    }
    set_text(h, IDC_CN_STATUS, &text);

    // A button that just got disabled can't keep the keyboard focus.
    let f = GetFocus();
    if !f.is_invalid() && !IsWindowEnabled(f).as_bool() {
        focus(h, if shown > 0 { IDC_CN_LIST } else { IDC_CN_ADD });
    }
}

unsafe fn do_connect(h: HWND, ctx: &Ctx) {
    let Some(r) = selected(h, ctx) else { return };
    if !can_connect(&r) {
        return;
    }
    *ctx.connect.borrow_mut() = Some(r.id);
    let _ = EndDialog(h, IDOK.0 as isize);
}

unsafe fn do_add(h: HWND, ctx: &Ctx) {
    if let Some((id, changed)) = edit_dialog(h, None) {
        if changed {
            ctx.restart.set(true);
        }
        // Show the new one even if the search would hide it.
        set_text(h, IDC_CN_SEARCH, "");
        refresh(h, ctx, Some(id));
    }
}

unsafe fn do_edit(h: HWND, ctx: &Ctx) {
    let Some(r) = selected(h, ctx) else { return };
    if let Some((id, changed)) = edit_dialog(h, Some(r.id)) {
        if changed {
            ctx.restart.set(true);
        }
        refresh(h, ctx, Some(id));
    }
}

unsafe fn do_duplicate(h: HWND, ctx: &Ctx) {
    let Some(r) = selected(h, ctx) else { return };
    let mut new = None;
    super::app::update_store(|c| new = logic::duplicate(c, &r.id));
    if new.is_some() {
        set_text(h, IDC_CN_SEARCH, "");
    }
    refresh(h, ctx, new.or(Some(r.id)));
}

unsafe fn do_remove(h: HWND, ctx: &Ctx) {
    let Some(r) = selected(h, ctx) else { return };
    let c = snapshot();
    let Some(s) = logic::get(&c, &r.id) else {
        refresh(h, ctx, None);
        return;
    };
    let key = s.pin_key(c.listen_port);
    let shared = c.connections.iter().any(|o| o.id != s.id && o.pin_key(c.listen_port) == key);
    let mut text = format!("Remove “{}”?", s.name);
    if r.paired {
        text.push_str(if shared {
            "\n\nIts pairing is kept: another saved connection uses the same address."
        } else {
            "\n\nIts pairing is forgotten too: if you add this Mac again, both screens show a code to confirm."
        });
    }
    if r.active {
        let next = c.connections.iter().find(|o| o.id != s.id && o.is_supported());
        text.push_str(&match next {
            Some(n) => format!("\n\nIt is the current connection: when you close this window, Glide switches to “{}”.", n.name),
            None => "\n\nIt is the current connection: when you close this window, Glide waits for the Mac to connect to this PC.".into(),
        });
    }
    if !confirm(h, &text) {
        return;
    }
    // Keep the selection in place: the next row, else the previous one.
    let neighbour = {
        let rows = ctx.rows.borrow();
        rows.iter().position(|x| x.id == r.id).and_then(|i| rows.get(i + 1).or(i.checked_sub(1).and_then(|p| rows.get(p)))).map(|x| x.id.clone())
    };
    let mut removed = None;
    super::app::update_store(|c| removed = logic::remove(c, &r.id));
    if removed.is_some_and(|x| x.was_active) {
        ctx.restart.set(true);
    }
    refresh(h, ctx, neighbour);
}

unsafe fn do_unpair(h: HWND, ctx: &Ctx) {
    let Some(r) = selected(h, ctx) else { return };
    if !r.paired {
        return;
    }
    let mut text = format!("Forget the pairing with “{}”?\n\nThe next time Glide connects to it, both screens show a code to confirm.", r.name);
    if r.active {
        text.push_str("\n\nIt is the current connection: Glide reconnects when you close this window.");
    }
    if !confirm(h, &text) {
        return;
    }
    let mut any = false;
    super::app::update_store(|c| any = logic::unpair(c, &r.id));
    if any && r.active {
        // The running session holds the old pin; a fresh viewer pairs cleanly.
        ctx.restart.set(true);
    }
    refresh(h, ctx, Some(r.id));
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

unsafe extern "system" fn conns_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &*(lp.0 as *const Ctx);
            let _ = SetWindowTextW(h, TITLE);
            set_text(h, IDC_CN_ADD, "&Add…");
            set_text(h, IDC_CN_EDIT, "&Edit…");
            cue(h, IDC_CN_SEARCH, "Search by name, address or group", true);
            set_icons(h, ctx);
            setup_list(h);
            refresh(h, ctx, None);
            let _ = SetForegroundWindow(h);
            if crate::util::test_hook("GLIDE_CONNS_DUMP").is_some() {
                SetTimer(Some(h), HOOK_TIMER, 500, None);
            }
            // Focus the list (return 0: we set the focus ourselves).
            let target = if ctx.rows.borrow().is_empty() { IDC_CN_ADD } else { IDC_CN_LIST };
            let _ = SetFocus(Some(item(h, target)));
            0
        }
        WM_TIMER if wp.0 == HOOK_TIMER => {
            let _ = KillTimer(Some(h), HOOK_TIMER);
            if let Some(p) = crate::util::test_hook("GLIDE_CONNS_DUMP") {
                match super::prompt::dump_window(h, &p) {
                    Ok((w, hh)) => eprintln!("connections: dumped {w}x{hh} window to {p}"),
                    Err(e) => eprintln!("connections: dump failed: {e}"),
                }
                let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(IDCANCEL.0 as usize), LPARAM(0));
            }
            1
        }
        WM_NOTIFY => {
            let Some(ctx) = ctx_of::<Ctx>(h) else { return 0 };
            let hdr = &*(lp.0 as *const NMHDR);
            if hdr.idFrom != IDC_CN_LIST as usize {
                return 0;
            }
            // Actions that open a window are posted, so they don't run inside the notification.
            let post = |id: i32| {
                let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(id as usize), LPARAM(0));
            };
            match hdr.code {
                LVN_ITEMCHANGED => {
                    let nm = &*(lp.0 as *const NMLISTVIEW);
                    if !ctx.refreshing.get() && (nm.uChanged.0 & LVIF_STATE.0) != 0 && ((nm.uNewState ^ nm.uOldState) & LVIS_SELECTED.0) != 0 {
                        update_selection(h, ctx);
                    }
                }
                NM_DBLCLK => {
                    let nm = &*(lp.0 as *const NMITEMACTIVATE);
                    if nm.iItem >= 0 {
                        post(IDOK.0);
                    }
                }
                LVN_KEYDOWN => {
                    let nm = &*(lp.0 as *const NMLVKEYDOWN);
                    if nm.wVKey == VK_DELETE.0 {
                        post(IDC_CN_REMOVE);
                    } else if nm.wVKey == VK_F2.0 {
                        post(IDC_CN_EDIT);
                    }
                }
                _ => return 0,
            }
            // These notifications ignore the result; say so explicitly.
            SetWindowLongPtrW(h, WINDOW_LONG_PTR_INDEX(DWLP_MSGRESULT as i32), 0);
            1
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            let code = ((wp.0 >> 16) & 0xFFFF) as u32;
            let Some(ctx) = ctx_of::<Ctx>(h) else { return 0 };
            match id {
                IDC_CN_SEARCH if code == EN_CHANGE => {
                    let keep = selected(h, ctx).map(|r| r.id);
                    refresh(h, ctx, keep);
                }
                IDC_CN_SEARCH => return 0,
                x if x == IDOK.0 => do_connect(h, ctx),
                IDC_CN_ADD => do_add(h, ctx),
                IDC_CN_EDIT => do_edit(h, ctx),
                IDC_CN_DUPLICATE => do_duplicate(h, ctx),
                IDC_CN_REMOVE => do_remove(h, ctx),
                IDC_CN_UNPAIR => do_unpair(h, ctx),
                x if x == IDCANCEL.0 => {
                    let _ = EndDialog(h, IDCANCEL.0 as isize);
                }
                _ => return 0,
            }
            1
        }
        _ => 0,
    }
}

// ---------------------------------------------------------------------------------------------
// Add / edit form

struct EditCtx {
    /// The id being edited; None = Add.
    editing: Option<String>,
    init: Draft,
    groups: Vec<String>,
    /// Test generation: a late answer for an address that has since changed is ignored.
    test_gen: Cell<u64>,
    /// Saved: (id, whether the viewer must restart to use the new target).
    outcome: RefCell<Option<(String, bool)>>,
}

/// Run the Add (`editing` None) / Edit form, modal to `owner`. Saves on Save and returns the
/// connection's id and whether the active target changed.
unsafe fn edit_dialog(owner: HWND, editing: Option<String>) -> Option<(String, bool)> {
    let c = snapshot();
    let init = match &editing {
        Some(id) => Draft::from_saved(logic::get(&c, id)?),
        None => Draft::new_default(),
    };
    let ctx = EditCtx { editing, init, groups: logic::groups(&c), test_gen: Cell::new(0), outcome: RefCell::new(None) };
    let hinst = GetModuleHandleW(None).ok()?;
    let r = DialogBoxParamW(Some(HINSTANCE(hinst.0)), PCWSTR(IDD_CONN_EDIT as usize as *const u16), Some(owner), Some(edit_proc), LPARAM(&ctx as *const EditCtx as isize));
    if r == -1 {
        eprintln!("connection form unavailable: {}", windows::core::Error::from_thread());
        return None;
    }
    ctx.outcome.into_inner()
}

unsafe fn sync_accept(h: HWND) {
    enable(h, IDC_CE_ACCEPT, !get_text(h, IDC_CE_ADDR).trim().is_empty());
}

unsafe fn start_test(h: HWND, ctx: &EditCtx) {
    let text = get_text(h, IDC_CE_ADDR);
    if text.trim().is_empty() {
        set_text(h, IDC_CE_TEST_RESULT, "Enter the Mac's address to test it. Without one, Glide waits for the Mac to connect to this PC.");
        return;
    }
    let addr = match crate::setup::normalize_address(&text) {
        Ok(a) => a,
        Err(e) => {
            set_text(h, IDC_CE_TEST_RESULT, &e);
            return;
        }
    };
    ctx.test_gen.set(ctx.test_gen.get() + 1);
    let gen = ctx.test_gen.get();
    set_text(h, IDC_CE_TEST_RESULT, &format!("Trying {addr}…"));
    enable(h, IDC_CE_TEST, false);
    let hh = h.0 as isize;
    std::thread::spawn(move || {
        let r = match crate::setup::test_reachable(&addr, Duration::from_secs(3)) {
            Ok(sa) => Ok(format!("The Mac answers on port {}.", sa.port())),
            Err(e) => Err(format!("No answer from {addr} ({e}). The Mac can still connect to this PC if you let it.")),
        };
        post_box(hh, WM_CE_TESTED, (gen, r, addr));
    });
}

unsafe fn save(h: HWND, ctx: &EditCtx) {
    let draft = Draft {
        name: get_text(h, IDC_CE_NAME),
        address: get_text(h, IDC_CE_ADDR),
        accept_incoming: checked(h, IDC_CE_ACCEPT),
        group: get_text(h, IDC_CE_GROUP),
        favorite: checked(h, IDC_CE_FAVORITE),
    };
    let editing = ctx.editing.as_deref();
    let mut res = logic::validate(&snapshot(), &draft, editing).map(|_| (String::new(), false));
    if res.is_ok() {
        super::app::update_store(|c| {
            res = match editing {
                Some(id) => logic::update(c, id, &draft).map(|changed| (id.to_string(), changed)),
                None => {
                    // The first connection becomes the active one, which may change the target.
                    let before = (c.host.clone(), c.accept_incoming);
                    logic::add(c, &draft).map(|id| (id, before != (c.host.clone(), c.accept_incoming)))
                }
            }
        });
    }
    match res {
        Ok(out) => {
            *ctx.outcome.borrow_mut() = Some(out);
            let _ = EndDialog(h, IDOK.0 as isize);
        }
        Err((field, msg)) => {
            set_text(h, IDC_CE_ERROR, &msg);
            show(h, IDC_CE_ERROR, true);
            focus(
                h,
                match field {
                    Field::Name => IDC_CE_NAME,
                    Field::Address => IDC_CE_ADDR,
                    Field::Group => IDC_CE_GROUP,
                },
            );
        }
    }
}

unsafe extern "system" fn edit_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &*(lp.0 as *const EditCtx);
            let _ = SetWindowTextW(h, if ctx.editing.is_some() { w!("Glide — Edit connection") } else { w!("Glide — Add connection") });
            send(item(h, IDC_CE_NAME), EM_LIMITTEXT, logic::MAX_NAME, 0);
            send(item(h, IDC_CE_GROUP), CB_LIMITTEXT, logic::MAX_NAME, 0);
            cue(h, IDC_CE_NAME, "Studio Mac", false);
            cue(h, IDC_CE_ADDR, "192.168.1.20 or mac.local — leave empty to wait for the Mac", false);
            let combo = item(h, IDC_CE_GROUP);
            for g in &ctx.groups {
                let t = wide(g);
                send(combo, CB_ADDSTRING, 0, t.as_ptr() as isize);
            }
            let ct = wide("None");
            send(combo, CB_SETCUEBANNER, 0, ct.as_ptr() as isize);
            set_text(h, IDC_CE_NAME, &ctx.init.name);
            set_text(h, IDC_CE_ADDR, &ctx.init.address);
            set_text(h, IDC_CE_GROUP, &ctx.init.group);
            check(h, IDC_CE_ACCEPT, ctx.init.accept_incoming);
            check(h, IDC_CE_FAVORITE, ctx.init.favorite);
            show(h, IDC_CE_ERROR, false);
            sync_accept(h);
            // Setting the address text above fired EN_CHANGE; nothing to clear yet.
            set_text(h, IDC_CE_TEST_RESULT, "");
            let _ = SetFocus(Some(item(h, IDC_CE_NAME)));
            send(item(h, IDC_CE_NAME), EM_SETSEL, 0, -1);
            0
        }
        WM_CE_TESTED => {
            let (gen, r, addr) = *Box::from_raw(lp.0 as *mut (u64, Result<String, String>, String));
            if let Some(ctx) = ctx_of::<EditCtx>(h) {
                enable(h, IDC_CE_TEST, true);
                let current = crate::setup::normalize_address(&get_text(h, IDC_CE_ADDR)).ok();
                if gen == ctx.test_gen.get() && current.as_deref() == Some(addr.as_str()) {
                    set_text(h, IDC_CE_TEST_RESULT, &r.unwrap_or_else(|e| e));
                }
            }
            1
        }
        WM_CTLCOLORSTATIC => {
            // The validation message in red.
            if HWND(lp.0 as *mut _) == item(h, IDC_CE_ERROR) {
                let dc = HDC(wp.0 as *mut _);
                SetTextColor(dc, COLORREF(0x0000_20C0));
                SetBkMode(dc, TRANSPARENT);
                return GetSysColorBrush(COLOR_BTNFACE).0 as isize;
            }
            0
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            let code = ((wp.0 >> 16) & 0xFFFF) as u32;
            let Some(ctx) = ctx_of::<EditCtx>(h) else { return 0 };
            match id {
                IDC_CE_TEST => start_test(h, ctx),
                IDC_CE_ADDR if code == EN_CHANGE => {
                    // A result for the old text no longer applies.
                    set_text(h, IDC_CE_TEST_RESULT, "");
                    sync_accept(h);
                }
                x if x == IDOK.0 => save(h, ctx),
                x if x == IDCANCEL.0 => {
                    let _ = EndDialog(h, IDCANCEL.0 as isize);
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

    fn row(last_used: &str) -> Row {
        Row {
            id: "c1".into(),
            name: "Studio Mac".into(),
            address: "192.168.1.20".into(),
            group: String::new(),
            status: "Not paired yet".into(),
            paired: false,
            last_used: last_used.into(),
            active: false,
            favorite: false,
            supported: true,
        }
    }

    #[test]
    fn phrases() {
        assert_eq!(last_used_phrase(&row("Never")), "Never used");
        assert_eq!(last_used_phrase(&row("Just now")), "Last used just now");
        assert_eq!(last_used_phrase(&row("2 hours ago")), "Last used 2 hours ago");
        assert_eq!(last_used_phrase(&row("Yesterday")), "Last used yesterday");
        assert_eq!(last_used_phrase(&row("2026-01-02")), "Last used on 2026-01-02");
        let mut r = row("Never");
        assert_eq!(name_label(&r), "Studio Mac");
        r.favorite = true;
        r.active = true;
        assert_eq!(name_label(&r), "★ Studio Mac (current)");
    }
}
