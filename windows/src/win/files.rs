//! File transfer UI glue (docs/PROTOCOL.md §6; the logic is in `crate::files`):
//!
//! - PC → Mac: files/folders dropped from Explorer onto the viewer window (`DragAcceptFiles` /
//!   WM_DROPFILES) are queued on the `files::Service`.
//! - Mac → PC: Ctrl+Alt+Shift+V asks the host for the files copied in Finder (FilePull); the Mac
//!   menu "Send Files to Viewer…" pushes offers directly. Files land in `<Downloads>\Glide`
//!   (config `download_dir`), marked with Mark-of-the-Web, and are never opened: the completion
//!   notification only opens the folder in Explorer (with the item selected).
//! - Progress is shown as a toast line; Ctrl+Alt+Shift+X or the tray menu cancels.
//!
//! Notices from the service threads are queued and handled on the UI thread (WM_APP_FILES).

use crate::config::Config;
use crate::files::{self, count_files, human_bytes, Limits, Notice, Service, ServiceConfig};
use crate::net::Sender;
use crate::protocol::{FileMsg, FILE_CAPS_SEND};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Posted to the viewer window when notices are queued.
pub const WM_APP_FILES: u32 = WM_APP + 0x70;

struct Ctx {
    service: Service,
    hwnd: AtomicIsize,
    notices: Mutex<VecDeque<Notice>>,
    /// What the "open folder" action shows: the last received items (or the download folder).
    last_received: Mutex<Option<(PathBuf, Vec<PathBuf>)>>,
    enabled: bool,
    test_sent: AtomicBool,
}

static CTX: OnceLock<Ctx> = OnceLock::new();

/// `<Downloads>\Glide` (the user's real Downloads folder, even if relocated).
fn default_download_dir() -> PathBuf {
    let known = unsafe {
        SHGetKnownFolderPath(&FOLDERID_Downloads, KNOWN_FOLDER_FLAG(0), None).ok().map(|p| {
            let s = p.to_string().unwrap_or_default();
            CoTaskMemFree(Some(p.0 as *const _));
            PathBuf::from(s)
        })
    };
    let downloads = known
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| std::env::var_os("USERPROFILE").map(|u| PathBuf::from(u).join("Downloads")));
    files::default_download_dir(downloads).unwrap_or_else(|| PathBuf::from("Glide"))
}

pub fn service_config(c: &Config) -> ServiceConfig {
    let dir = c.download_dir.as_deref().map(|d| PathBuf::from(expand_env(d))).unwrap_or_else(default_download_dir);
    ServiceConfig {
        download_dir: dir,
        limits: Limits { max_total_bytes: c.file_max_total_bytes, max_files: c.file_max_files },
        receive: c.file_receive,
        mark: files::mark_downloaded,
        host_role: false,
    }
}

/// `%USERPROFILE%\...` style variables in the configured folder.
fn expand_env(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        match after.find('%') {
            Some(j) => {
                let name = &after[..j];
                match std::env::var(name) {
                    Ok(v) if !name.is_empty() => out.push_str(&v),
                    _ => {
                        out.push('%');
                        out.push_str(name);
                        out.push('%');
                    }
                }
                rest = &after[j + 1..];
            }
            None => {
                out.push('%');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Is this process elevated (UAC "Run as administrator")?
fn elevated() -> bool {
    use windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    unsafe {
        let mut tok = HANDLE::default();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut tok).is_err() {
            return false;
        }
        let mut e = TOKEN_ELEVATION::default();
        let mut len = 0u32;
        let ok = GetTokenInformation(tok, TokenElevation, Some(&mut e as *mut _ as *mut _), std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut len).is_ok();
        let _ = CloseHandle(tok);
        ok && e.TokenIsElevated != 0
    }
}

/// UI thread, once, after the window exists. Returns a message for the user, if any.
pub fn init(hwnd: HWND, c: &Config) -> Option<String> {
    let cfg = service_config(c);
    eprintln!(
        "files: transfer {} — receive {} into {}, limits {} / {} files",
        if c.file_transfer { "on" } else { "off" },
        if c.file_receive { "on" } else { "off" },
        cfg.download_dir.display(),
        human_bytes(cfg.limits.max_total_bytes),
        cfg.limits.max_files
    );
    let service = Service::start(cfg, |n| {
        let Some(ctx) = CTX.get() else { return };
        ctx.notices.lock().unwrap().push_back(n);
        unsafe {
            let _ = PostMessageW(Some(HWND(ctx.hwnd.load(Ordering::Relaxed) as *mut _)), WM_APP_FILES, WPARAM(0), LPARAM(0));
        }
    });
    let _ = CTX.set(Ctx {
        service,
        hwnd: AtomicIsize::new(hwnd.0 as isize),
        notices: Mutex::new(VecDeque::new()),
        last_received: Mutex::new(None),
        enabled: c.file_transfer,
        test_sent: AtomicBool::new(false),
    });
    if !c.file_transfer {
        return None;
    }
    unsafe { DragAcceptFiles(hwnd, true) };
    // The UIPI message filter is deliberately left strict: relaxing it for an elevated viewer
    // would let any lower-integrity process post WM_DROPFILES and make us send arbitrary files to
    // the Mac. Elevated, drops from a normal Explorer are blocked by Windows; say so.
    if elevated() {
        eprintln!("files: running elevated: drag & drop from Explorer is blocked by Windows (UIPI); use the Glide menu's Send files…");
        return Some("Drag & drop is disabled while Glide runs as administrator — use the Glide menu → Send files to the Mac…".into());
    }
    None
}

fn ctx() -> Option<&'static Ctx> {
    CTX.get().filter(|c| c.enabled)
}

/// Session thread: a connection is up.
pub fn connected(sender: Sender) {
    let Some(c) = ctx() else { return };
    let send: files::SendFn = Arc::new(move |m: &FileMsg, bulk: bool| {
        let pt = m.encode();
        if bulk {
            sender.send_bulk_plaintext(&pt)
        } else {
            sender.send_plaintext(&pt)
        }
    });
    c.service.connected(send);
}

pub fn disconnected() {
    if let Some(c) = ctx() {
        c.service.disconnected();
    }
}

/// Receive thread: a file message from the host.
pub fn incoming(m: FileMsg) {
    let Some(c) = ctx() else { return };
    if let FileMsg::Caps { flags, max_total_bytes, max_files } = &m {
        eprintln!("files: host caps flags {flags:#x}, accepts up to {} / {max_files} files", human_bytes(*max_total_bytes));
        // Test hook: GLIDE_TEST_SEND_FILES="C:\a;C:\b" sends these once the host is ready
        // (drag & drop can't be scripted over SSH).
        if let Some(v) = crate::util::test_hook("GLIDE_TEST_SEND_FILES") {
            if !c.test_sent.swap(true, Ordering::Relaxed) {
                let paths: Vec<PathBuf> = v.split(';').filter(|s| !s.is_empty()).map(PathBuf::from).collect();
                let svc = c.service.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    eprintln!("files: test hook sending {paths:?}");
                    svc.send_paths(paths);
                });
            }
        }
    }
    c.service.on_message(m);
}

/// WM_DROPFILES: send the dropped files/folders to the Mac.
pub fn on_drop(hdrop: HDROP) -> Option<String> {
    let mut paths = Vec::new();
    unsafe {
        let n = DragQueryFileW(hdrop, u32::MAX, None);
        for i in 0..n {
            let len = DragQueryFileW(hdrop, i, None) as usize;
            let mut buf = vec![0u16; len + 1];
            let got = DragQueryFileW(hdrop, i, Some(&mut buf)) as usize;
            paths.push(PathBuf::from(String::from_utf16_lossy(&buf[..got.min(len)])));
        }
        DragFinish(hdrop);
    }
    let c = ctx()?;
    eprintln!("files: dropped {paths:?}");
    if paths.is_empty() {
        return None;
    }
    let first = paths[0].file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let what = if paths.len() == 1 { format!("“{first}”") } else { format!("{} items", paths.len()) };
    c.service.send_paths(paths);
    Some(format!("Sending {what} to the Mac…"))
}

/// Ctrl+Alt+Shift+V: ask the Mac for the files copied in Finder.
pub fn pull() -> String {
    let Some(c) = ctx() else { return "File transfer is turned off (config file_transfer)".into() };
    if c.service.peer_flags().is_some_and(|f| f & FILE_CAPS_SEND == 0) {
        return "This host can't send files".into();
    }
    match c.service.pull() {
        Ok(()) => "Asking the Mac for the files copied in Finder…".into(),
        Err(e) => format!("Can't paste files: {e}"),
    }
}

/// Ctrl+Alt+Shift+X / tray: cancel transfers.
pub fn cancel() -> String {
    match ctx() {
        Some(c) if c.service.cancel_all() => "File transfer cancelled".into(),
        _ => "No file transfer in progress".into(),
    }
}

/// FileCaps flags of the connected host (None: not negotiated).
pub fn peer_flags() -> Option<u32> {
    ctx()?.service.peer_flags()
}

/// Menu "Send files…" / "Send folder…": native picker (multi-select) → send to the Mac.
/// Returns a toast, or None if the user cancelled.
pub fn pick_and_send(hwnd: HWND, folders: bool) -> Option<String> {
    let c = ctx()?;
    let paths = match pick(hwnd, folders) {
        Ok(p) => p,
        Err(e) => return Some(format!("Can't open the file picker: {e}")),
    };
    if paths.is_empty() {
        return None;
    }
    eprintln!("files: picked {paths:?}");
    let what = match paths.as_slice() {
        [one] => format!("“{}”", one.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()),
        many => format!("{} items", many.len()),
    };
    c.service.send_paths(paths);
    Some(format!("Sending {what} to the Mac…"))
}

/// IFileOpenDialog with FOS_ALLOWMULTISELECT (+ FOS_PICKFOLDERS for folders), file-system items only.
fn pick(hwnd: HWND, folders: bool) -> windows::core::Result<Vec<PathBuf>> {
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
    unsafe {
        // The UI thread is (or becomes) an STA; S_FALSE / RPC_E_CHANGED_MODE are fine here.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let dlg: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;
        let mut opts = dlg.GetOptions()? | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
        if folders {
            opts |= FOS_PICKFOLDERS;
        } else {
            opts |= FOS_FILEMUSTEXIST;
        }
        dlg.SetOptions(opts)?;
        let title: Vec<u16> =
            if folders { "Send folders to the Mac" } else { "Send files to the Mac" }.encode_utf16().chain(std::iter::once(0)).collect();
        dlg.SetTitle(PCWSTR(title.as_ptr()))?;
        dlg.SetOkButtonLabel(w!("Send"))?;
        if let Err(e) = dlg.Show(Some(hwnd)) {
            // ERROR_CANCELLED
            return if e.code() == windows::core::HRESULT::from_win32(1223) { Ok(Vec::new()) } else { Err(e) };
        }
        let items = dlg.GetResults()?;
        let mut out = Vec::new();
        for i in 0..items.GetCount()? {
            let p = items.GetItemAt(i)?.GetDisplayName(SIGDN_FILESYSPATH)?;
            let s = p.to_string().unwrap_or_default();
            CoTaskMemFree(Some(p.0 as *const _));
            if !s.is_empty() {
                out.push(PathBuf::from(s));
            }
        }
        Ok(out)
    }
}

pub fn busy() -> bool {
    ctx().is_some_and(|c| c.service.busy())
}

pub fn enabled() -> bool {
    ctx().is_some()
}

/// One status line while transfers run (shown as a toast), e.g.
/// "Receiving 3 files from the Mac — 45% · 12 MB of 27 MB · Ctrl+Alt+Shift+X cancels".
pub fn progress_line() -> Option<String> {
    let p = ctx()?.service.progress();
    if p.is_empty() {
        return None;
    }
    let parts: Vec<String> = p
        .iter()
        .map(|p| {
            let pct = p.done.saturating_mul(100).checked_div(p.total).unwrap_or(100).min(100);
            format!(
                "{} {} {} the Mac — {pct}% · {} of {}",
                if p.incoming { "Receiving" } else { "Sending" },
                count_files(p.files),
                if p.incoming { "from" } else { "to" },
                human_bytes(p.done),
                human_bytes(p.total)
            )
        })
        .collect();
    Some(format!("{} · Ctrl+Alt+Shift+X cancels", parts.join(" | ")))
}

/// What the UI should show for one notice: (toast text, optional balloon (title, body)).
pub struct Shown {
    pub toast: String,
    pub balloon: Option<(String, String)>,
}

/// UI thread (WM_APP_FILES): drain the queued notices.
pub fn take_notices() -> Vec<Shown> {
    let Some(c) = CTX.get() else { return Vec::new() };
    let drained: Vec<Notice> = c.notices.lock().unwrap().drain(..).collect();
    drained
        .into_iter()
        .filter_map(|n| match n {
            Notice::Received { files, bytes, dir, items } => {
                let where_ = dir.display().to_string();
                *c.last_received.lock().unwrap() = Some((dir, items));
                Some(Shown {
                    toast: format!("Received {} ({}) — click the Glide notification or use the tray to open the folder", count_files(files), human_bytes(bytes)),
                    balloon: Some((format!("Received {} from the Mac", count_files(files)), format!("Saved to {where_}. Click to show in Explorer."))),
                })
            }
            Notice::Sent { files, bytes } => Some(Shown { toast: format!("Sent {} ({}) to the Mac", count_files(files), human_bytes(bytes)), balloon: None }),
            Notice::Started { .. } => None, // the progress line takes over
            Notice::Failed(m) => Some(Shown { toast: m.clone(), balloon: Some(("Glide file transfer".into(), m)) }),
            Notice::Info(m) => Some(Shown { toast: m, balloon: None }),
        })
        .collect()
}

/// Show the received files in Explorer (selected), never open them.
pub fn open_folder() {
    let Some(c) = CTX.get() else { return };
    let last = c.last_received.lock().unwrap().clone();
    let dir = c.service.download_dir();
    let (folder, select) = match last {
        Some((d, items)) => (d, items.into_iter().next()),
        None => (dir, None),
    };
    let _ = std::fs::create_dir_all(&folder);
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() };
    unsafe {
        match select {
            Some(item) => {
                let args = wide(&format!("/select,\"{}\"", item.display()));
                ShellExecuteW(None, w!("open"), w!("explorer.exe"), PCWSTR(args.as_ptr()), None, SW_SHOWNORMAL);
            }
            None => {
                let f = wide(&folder.display().to_string());
                // "explore" opens the folder itself in Explorer (a folder is never "run").
                ShellExecuteW(None, w!("explore"), PCWSTR(f.as_ptr()), None, None, SW_SHOWNORMAL);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn env_expansion() {
        std::env::set_var("GLIDE_T_X", "C:\\Users\\me");
        assert_eq!(super::expand_env("%GLIDE_T_X%\\Downloads"), "C:\\Users\\me\\Downloads");
        assert_eq!(super::expand_env("100%"), "100%");
        assert_eq!(super::expand_env("%NOPE_NOT_SET_X%\\a"), "%NOPE_NOT_SET_X%\\a");
    }
}
