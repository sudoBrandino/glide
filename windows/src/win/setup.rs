//! The setup dialog (`IDD_SETUP` in res/glide.rc): everything a first start needs, without
//! PowerShell or a command line.
//!
//! - **Mac's address** + **Test** (TCP connect to its Glide port, in the background).
//! - **This PC's address**, for the Mac's own setup window when only Mac → PC connections work.
//! - **Let the Mac connect to this PC** (config `accept_incoming`; with an address the viewer
//!   dials *and* listens, see `app::both_round`) + **Allow in Windows Firewall**: one elevated
//!   PowerShell step (UAC shield) that removes Block rules for the exe and adds an Allow rule.
//! - **Start Glide when I sign in** (HKCU Run value, with `--startup`: it opens without connecting
//!   unless config `connect_at_signin`; see `crate::signin`).
//! - **Install Glide Viewer on this PC** when the exe runs from somewhere else (Downloads): copy to
//!   `%LOCALAPPDATA%\Glide` (or the folder the Start Menu shortcut points to), create the Start
//!   Menu shortcut, close an installed viewer that is running (asks first), start the installed
//!   copy. The source file is never deleted.
//!
//! It opens by itself at startup when nothing is set up or the exe isn't installed (`at_startup`),
//! and from the Glide menu / tray ("Set up…", `from_menu`; Connect there restarts the viewer).
//!
//! Test hooks (nobody to click; `test-hooks` builds only, see `util::test_hook`):
//! `GLIDE_SETUP_DUMP=x.bmp` saves a capture of the dialog, `GLIDE_SETUP_ANSWER=connect|cancel`
//! presses the button after ~0.5 s.

use crate::config::{Config, Store};
use crate::setup::{self as logic, FirewallStatus};
use std::path::{Path, PathBuf};
use std::time::Duration;
use windows::core::{w, Interface, BOOL, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, IPersistFile, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, STGM_READ};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_SZ};
use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
use windows::Win32::UI::Controls::{CheckDlgButton, IsDlgButtonChecked, BCM_SETSHIELD, BST_CHECKED, BST_UNCHECKED};
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows::Win32::UI::Shell::{IShellLinkW, ShellExecuteExW, ShellLink, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_SETUP: u16 = 103;
const IDC_SU_ICON: i32 = 1200;
const IDC_SU_ADDR: i32 = 1202;
const IDC_SU_TEST: i32 = 1203;
const IDC_SU_TEST_RESULT: i32 = 1204;
const IDC_SU_ACCEPT: i32 = 1205;
const IDC_SU_FIREWALL: i32 = 1206;
const IDC_SU_FW_STATUS: i32 = 1207;
const IDC_SU_THIS_PC: i32 = 1208;
const IDC_SU_AUTOSTART: i32 = 1209;
const IDC_SU_INSTALL: i32 = 1210;
const IDC_SU_INSTALL_NOTE: i32 = 1211;

/// Background → dialog: Box<(generation, Result<text, text>)> of a Test.
const WM_SU_TESTED: u32 = WM_APP + 1;
/// Background → dialog: Box<Option<FirewallStatus>>.
const WM_SU_FIREWALL: u32 = WM_APP + 2;
const HOOK_TIMER: usize = 1;

const RUN_KEY: PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const EXE_NAME: &str = "glide-client.exe";
/// CREATE_NO_WINDOW: the firewall check's PowerShell never flashes a console.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// What `at_startup` decided.
pub enum Startup {
    /// Run the viewer (with the possibly updated config).
    Continue,
    /// The dialog was shown and the user clicked Connect: run the viewer and connect, even when
    /// it was started at sign-in (which otherwise opens disconnected).
    Connect,
    /// The installed copy was started: exit this process.
    Exit,
}

/// What the dialog starts with.
#[derive(Clone)]
struct Init {
    addr: String,
    accept: bool,
    autostart: bool,
    offer_install: bool,
    install_dir: PathBuf,
    exe: PathBuf,
    port: u16,
    /// Installed per machine (Program Files) or deployed by an organization (HKLM Glide policy):
    /// the installer owns the location, sign-in start and the firewall rule, so the dialog
    /// offers none of them.
    deployed: bool,
}

/// Installed per machine (the MSI, under Program Files) or the organization's Glide policy key
/// exists in HKLM.
pub(super) fn deployed() -> bool {
    logic::machine_installed(&current_exe(), |k| std::env::var(k).ok()) || crate::cloud::managed::registry::RegSource::machine_policy_exists()
}

/// What the user chose (Connect).
#[derive(Debug, Clone, PartialEq)]
struct Choice {
    host: Option<String>,
    accept: bool,
    autostart: bool,
    install: bool,
}

struct Ctx {
    init: Init,
    choice: Option<Choice>,
    /// Test generation: a late answer for an address that has since changed is ignored.
    test_gen: u64,
    icons: Vec<HICON>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn appdata_path(rel: &str) -> Option<PathBuf> {
    std::env::var_os("APPDATA").filter(|s| !s.is_empty()).map(|a| PathBuf::from(a).join(rel))
}

/// Start Menu → Programs → "Glide Viewer.lnk".
fn start_menu_shortcut() -> Option<PathBuf> {
    appdata_path("Microsoft\\Windows\\Start Menu\\Programs").map(|d| d.join(logic::SHORTCUT_NAME))
}

/// The Startup folder's "Glide Viewer.lnk" (install.ps1's sign-in shortcut).
fn startup_shortcut() -> Option<PathBuf> {
    appdata_path("Microsoft\\Windows\\Start Menu\\Programs\\Startup").map(|d| d.join(logic::SHORTCUT_NAME))
}

/// Run `f` on a short-lived thread with its own STA COM apartment (the UI thread's apartment
/// model is the app's business; MF/WASAPI use MTA elsewhere).
fn with_com<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    std::thread::spawn(move || unsafe {
        let ok = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
        let r = f();
        if ok {
            CoUninitialize();
        }
        r
    })
    .join()
    .ok()
}

/// (target exe, arguments) of a .lnk file.
fn read_shortcut(lnk: PathBuf) -> Option<(PathBuf, String)> {
    with_com(move || unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).ok()?;
        let pf: IPersistFile = link.cast().ok()?;
        pf.Load(PCWSTR(wide(&lnk.to_string_lossy()).as_ptr()), STGM_READ).ok()?;
        let mut path = [0u16; 1024];
        link.GetPath(&mut path, std::ptr::null_mut(), 0).ok()?;
        let mut args = [0u16; 1024];
        let _ = link.GetArguments(&mut args);
        let s = |b: &[u16]| String::from_utf16_lossy(&b[..b.iter().position(|&c| c == 0).unwrap_or(b.len())]);
        let p = s(&path);
        (!p.is_empty()).then(|| (PathBuf::from(p), s(&args)))
    })
    .flatten()
}

/// Create (or overwrite) a .lnk to `target` with no arguments (the config says where to connect).
fn write_shortcut(lnk: PathBuf, target: PathBuf) -> Result<(), String> {
    write_shortcut_with_args(lnk, target, String::new())
}

fn write_shortcut_with_args(lnk: PathBuf, target: PathBuf, args: String) -> Result<(), String> {
    with_com(move || unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(|e| e.to_string())?;
        link.SetPath(PCWSTR(wide(&target.to_string_lossy()).as_ptr())).map_err(|e| e.to_string())?;
        link.SetArguments(PCWSTR(wide(&args).as_ptr())).map_err(|e| e.to_string())?;
        if let Some(dir) = target.parent() {
            let _ = link.SetWorkingDirectory(PCWSTR(wide(&dir.to_string_lossy()).as_ptr()));
        }
        let _ = link.SetDescription(w!("Glide viewer: control your Mac"));
        if let Some(dir) = lnk.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let pf: IPersistFile = link.cast().map_err(|e| e.to_string())?;
        pf.Save(PCWSTR(wide(&lnk.to_string_lossy()).as_ptr()), true).map_err(|e| e.to_string())
    })
    .unwrap_or_else(|| Err("shortcut thread failed".into()))
}

/// Where the viewer is installed: the folder the Start Menu shortcut points to (an earlier
/// install.ps1 or setup), else `%LOCALAPPDATA%\Glide`.
fn install_dir() -> PathBuf {
    if let Some((target, _)) = start_menu_shortcut().filter(|p| p.exists()).and_then(read_shortcut) {
        if let Some(d) = target.parent().filter(|d| d.join(EXE_NAME).exists()) {
            return d.to_path_buf();
        }
    }
    logic::default_install_dir(|k| std::env::var(k).ok()).unwrap_or_else(|| PathBuf::from("C:\\Glide"))
}

fn run_value_get() -> Option<String> {
    unsafe {
        let name = wide(logic::RUN_VALUE);
        let mut buf = [0u16; 1024];
        let mut len = (buf.len() * 2) as u32;
        let r = RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, PCWSTR(name.as_ptr()), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr().cast()), Some(&mut len));
        if r != ERROR_SUCCESS {
            return None;
        }
        let n = (len as usize / 2).saturating_sub(1).min(buf.len());
        Some(String::from_utf16_lossy(&buf[..n]))
    }
}

/// Starts at sign-in now: the Run value, or install.ps1's Startup shortcut.
pub(super) fn autostart_on() -> bool {
    run_value_get().is_some() || startup_shortcut().is_some_and(|p| p.exists())
}

/// Turn start-at-sign-in on (Run value → `exe --startup`) or off. An install.ps1 Startup
/// shortcut is removed either way (it may carry old arguments, and two entries start twice).
pub(super) fn set_autostart(on: bool, exe: &Path) -> Result<(), String> {
    if let Some(s) = startup_shortcut().filter(|p| p.exists()) {
        let _ = std::fs::remove_file(s);
    }
    unsafe {
        let name = wide(logic::RUN_VALUE);
        if on {
            let v = wide(&logic::run_value(exe));
            let r = RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, PCWSTR(name.as_ptr()), REG_SZ.0, Some(v.as_ptr().cast()), (v.len() * 2) as u32);
            if r != ERROR_SUCCESS {
                return Err(format!("can't write the sign-in entry ({})", windows::core::Error::from(r.to_hresult())));
            }
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, PCWSTR(name.as_ptr()));
        }
    }
    Ok(())
}

/// At startup: a sign-in entry written before `--startup` existed (Run value, or an older
/// install.ps1's Startup shortcut) gets it, so sign-in opens without connecting. Only entries
/// that start this exe: an older copy elsewhere wouldn't know the flag (`signin` has the rules).
pub fn migrate_signin_entry() {
    if deployed() {
        return; // a per-machine install manages sign-in start itself
    }
    let exe = current_exe();
    if let Some(v) = run_value_get().and_then(|v| crate::signin::migrate_run_value(&v, &exe)) {
        let name = wide(logic::RUN_VALUE);
        let w = wide(&v);
        let r = unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, PCWSTR(name.as_ptr()), REG_SZ.0, Some(w.as_ptr().cast()), (w.len() * 2) as u32) };
        if r == ERROR_SUCCESS {
            eprintln!("setup: sign-in entry now opens Glide without connecting ({v})");
        } else {
            eprintln!("setup: can't update the sign-in entry ({})", windows::core::Error::from(r.to_hresult()));
        }
    }
    let Some(lnk) = startup_shortcut().filter(|p| p.exists()) else { return };
    if let Some((target, args)) = read_shortcut(lnk.clone()) {
        if let Some(new_args) = crate::signin::migrate_shortcut_args(&target, &args, &exe) {
            match write_shortcut_with_args(lnk, target, new_args) {
                Ok(()) => eprintln!("setup: Startup shortcut now opens Glide without connecting"),
                Err(e) => eprintln!("setup: can't update the Startup shortcut: {e}"),
            }
        }
    }
}

fn message(owner: Option<HWND>, text: &str, flags: MESSAGEBOX_STYLE) -> MESSAGEBOX_RESULT {
    let t = wide(text);
    unsafe { MessageBoxW(owner, PCWSTR(t.as_ptr()), w!("Glide — Set up"), flags) }
}

/// Other viewer windows (class GlideViewer) and their process ids.
fn other_viewers() -> Vec<(HWND, u32)> {
    unsafe extern "system" fn each(h: HWND, lp: LPARAM) -> BOOL {
        let out = &mut *(lp.0 as *mut Vec<(HWND, u32)>);
        let mut class = [0u16; 32];
        let n = GetClassNameW(h, &mut class) as usize;
        if String::from_utf16_lossy(&class[..n]) == "GlideViewer" {
            let mut pid = 0u32;
            GetWindowThreadProcessId(h, Some(&mut pid));
            if pid != std::process::id() {
                out.push((h, pid));
            }
        }
        TRUE
    }
    let mut out: Vec<(HWND, u32)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

/// Copy this exe (and README/LICENSE beside it) into `dir`, write the Start Menu shortcut.
/// Closes a running viewer of another process first, after asking. Returns the installed exe.
fn install(owner: Option<HWND>, exe: &Path, dir: &Path) -> Result<PathBuf, String> {
    let others = other_viewers();
    if !others.is_empty() {
        let r = message(owner, "Glide Viewer is running. Close it and install this copy?", MB_OKCANCEL | MB_ICONQUESTION);
        if r != IDOK {
            return Err("cancelled: Glide Viewer is still running".into());
        }
        unsafe {
            let procs: Vec<HANDLE> = others.iter().filter_map(|(_, pid)| OpenProcess(PROCESS_SYNCHRONIZE, false, *pid).ok()).collect();
            for (h, _) in &others {
                let _ = PostMessageW(Some(*h), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
            for p in procs {
                let _ = WaitForSingleObject(p, 5000);
                let _ = CloseHandle(p);
            }
        }
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
    let dest = dir.join(EXE_NAME);
    // The old exe can stay locked for a moment after its process exits.
    let mut last = None;
    for _ in 0..20 {
        match std::fs::copy(exe, &dest) {
            Ok(_) => {
                last = None;
                break;
            }
            Err(e) => {
                last = Some(e);
                std::thread::sleep(Duration::from_millis(250));
            }
        }
    }
    if let Some(e) = last {
        return Err(format!("can't copy to {}: {e}", dest.display()));
    }
    if let Some(src) = exe.parent() {
        for f in logic::EXTRA_FILES {
            if src.join(f).exists() {
                let _ = std::fs::copy(src.join(f), dir.join(f));
            }
        }
    }
    if let Some(lnk) = start_menu_shortcut() {
        if let Err(e) = write_shortcut(lnk, dest.clone()) {
            eprintln!("setup: Start Menu shortcut: {e}");
        }
    }
    eprintln!("setup: installed {} → {}", exe.display(), dest.display());
    Ok(dest)
}

/// A Start Menu shortcut with arguments (install.ps1 put the Mac's address or --listen there)
/// would override what the user just chose: point it at `exe` without arguments.
fn fix_shortcut_arguments(exe: &Path) {
    let Some(lnk) = start_menu_shortcut().filter(|p| p.exists()) else { return };
    if let Some((target, args)) = read_shortcut(lnk.clone()) {
        if !args.trim().is_empty() && logic::same_path(&target, exe) {
            if let Err(e) = write_shortcut(lnk, target) {
                eprintln!("setup: can't update the Start Menu shortcut: {e}");
            }
        }
    }
}

pub(super) fn spawn(exe: &Path) -> Result<(), String> {
    spawn_args(exe, &["--after-setup".to_string()])
}

/// Start `exe` with exactly these arguments (from its own folder).
pub(super) fn spawn_args(exe: &Path, args: &[String]) -> Result<(), String> {
    let mut c = std::process::Command::new(exe);
    c.args(args);
    if let Some(d) = exe.parent() {
        c.current_dir(d);
    }
    c.spawn().map(|_| ()).map_err(|e| format!("can't start {}: {e}", exe.display()))
}

pub(super) fn current_exe() -> PathBuf {
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from(EXE_NAME))
}

fn make_init(store: &Store) -> Init {
    let exe = current_exe();
    let dir = install_dir();
    let c = &store.config;
    let deployed = deployed();
    Init {
        addr: c.host.clone().unwrap_or_default(),
        accept: c.accept_incoming,
        autostart: autostart_on(),
        offer_install: !deployed && logic::offer_install(&exe, &dir, c.portable_exe.as_deref()),
        install_dir: dir,
        exe,
        port: c.listen_port,
        deployed,
    }
}

/// Install if asked, set start-at-sign-in, fix the shortcut. Returns the exe that runs from now
/// on, whether it is a newly installed copy (to be started), and the exe to remember as run in
/// place (declined the install). The config is saved separately (`save_choice`), so the store
/// isn't locked while dialogs are up.
fn apply(owner: Option<HWND>, init: &Init, ch: &Choice) -> (PathBuf, bool, Option<String>) {
    let mut exe = init.exe.clone();
    let mut installed = false;
    if ch.install {
        match install(owner, &init.exe, &init.install_dir) {
            Ok(p) => {
                exe = p;
                installed = true;
            }
            Err(e) => {
                message(owner, &format!("Glide could not be installed: {e}\n\nIt will run from where it is."), MB_OK | MB_ICONWARNING);
            }
        }
    }
    let portable = (init.offer_install && !installed).then(|| init.exe.to_string_lossy().into_owned());
    // Also when on: point it at a newly installed copy, and replace an install.ps1 Startup
    // shortcut (it may carry old arguments that would override the new settings). A per-machine
    // install leaves sign-in start to the installer.
    if !init.deployed && (ch.autostart != init.autostart || (ch.autostart && (installed || startup_shortcut().is_some_and(|p| p.exists())))) {
        if let Err(e) = set_autostart(ch.autostart, &exe) {
            message(owner, &format!("Start at sign-in: {e}"), MB_OK | MB_ICONWARNING);
        }
    }
    fix_shortcut_arguments(&exe);
    (exe, installed, portable)
}

fn save_choice(c: &mut Config, ch: &Choice, portable: Option<String>) {
    c.host = ch.host.clone();
    c.accept_incoming = ch.accept;
    // Right away, not on the next load: the Connections window and tray read the saved list
    // from this same live config.
    crate::connections::sync_from_host(c);
    if portable.is_some() {
        c.portable_exe = portable;
    }
}

/// At startup (no CLI target): show the dialog when nothing is set up, the exe isn't installed,
/// or `forced` (--setup). May install and start the installed copy.
pub fn at_startup(store: &mut Store, forced: bool) -> Startup {
    let init = make_init(store);
    if !forced && !store.config.needs_setup() && !init.offer_install {
        return Startup::Continue;
    }
    // Deployed by an organization (HKLM Glide policy): don't pop the LAN setup dialog by itself;
    // the organization's computers are in Connections… (Set up… stays in the menus).
    if !forced && crate::cloud::managed::registry::RegSource::machine_policy_exists() {
        return Startup::Continue;
    }
    let Some(ch) = run_dialog(None, init.clone()) else { return Startup::Continue };
    let (exe, installed, portable) = apply(None, &init, &ch);
    store.update(|c| save_choice(c, &ch, portable));
    if installed {
        match spawn(&exe) {
            Ok(()) => return Startup::Exit,
            Err(e) => {
                message(None, &e, MB_OK | MB_ICONWARNING);
            }
        }
    }
    Startup::Connect
}

/// "Set up…" (Glide menu / tray): Connect saves, then restarts the viewer with the new settings
/// (or starts the newly installed copy).
pub fn from_menu(hwnd: HWND) {
    let init = make_init(&super::app::store_snapshot());
    let Some(ch) = run_dialog(Some(hwnd), init.clone()) else { return };
    let before = (init.addr.trim().to_string(), init.accept);
    let (exe, installed, portable) = apply(Some(hwnd), &init, &ch);
    super::app::update_store(|c| save_choice(c, &ch, portable));
    let changed = before != (ch.host.clone().unwrap_or_default(), ch.accept);
    if installed || changed {
        match spawn(&exe) {
            Ok(()) => unsafe {
                let _ = DestroyWindow(hwnd);
            },
            Err(e) => {
                message(Some(hwnd), &e, MB_OK | MB_ICONWARNING);
            }
        }
    }
}

fn run_dialog(owner: Option<HWND>, init: Init) -> Option<Choice> {
    let mut ctx = Ctx { init, choice: None, test_gen: 0, icons: Vec::new() };
    let r = unsafe {
        let hinst = GetModuleHandleW(None).ok()?;
        DialogBoxParamW(Some(HINSTANCE(hinst.0)), PCWSTR(IDD_SETUP as usize as *const u16), owner, Some(dlg_proc), LPARAM(&mut ctx as *mut Ctx as isize))
    };
    unsafe {
        for i in ctx.icons.drain(..) {
            let _ = DestroyIcon(i);
        }
    }
    if r == -1 {
        eprintln!("setup dialog unavailable: {}", windows::core::Error::from_thread());
        return None;
    }
    ctx.choice
}

unsafe fn ctx_of(h: HWND) -> Option<&'static mut Ctx> {
    let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *mut Ctx;
    p.as_mut()
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

/// Post `v` to the dialog, or drop it if the dialog is gone.
fn post_box<T>(h: isize, msg: u32, v: T) {
    let p = Box::into_raw(Box::new(v));
    unsafe {
        if PostMessageW(Some(HWND(h as *mut _)), msg, WPARAM(0), LPARAM(p as isize)).is_err() {
            drop(Box::from_raw(p));
        }
    }
}

/// The exe the firewall rule must name: the installed copy if "Install" is ticked.
unsafe fn firewall_exe(h: HWND, ctx: &Ctx) -> PathBuf {
    if ctx.init.offer_install && checked(h, IDC_SU_INSTALL) {
        ctx.init.install_dir.join(EXE_NAME)
    } else {
        ctx.init.exe.clone()
    }
}

/// Windows PowerShell by its full path in the system folder, never through the search path (the
/// current or the exe's folder could hold a planted powershell.exe, and one call is elevated).
fn powershell_path() -> PathBuf {
    let mut buf = [0u16; 260];
    let n = unsafe { windows::Win32::System::SystemInformation::GetSystemDirectoryW(Some(&mut buf)) } as usize;
    let sys = if n > 0 && n < buf.len() { PathBuf::from(String::from_utf16_lossy(&buf[..n])) } else { PathBuf::from(r"C:\Windows\System32") };
    sys.join(r"WindowsPowerShell\v1.0\powershell.exe")
}

fn run_firewall_check(exe: &Path) -> Option<FirewallStatus> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new(powershell_path())
        .args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &logic::ps_encode(&logic::firewall_check_script(&exe.to_string_lossy()))])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    FirewallStatus::parse(&String::from_utf8_lossy(&out.stdout))
}

unsafe fn start_firewall_check(h: HWND, ctx: &Ctx) {
    if ctx.init.deployed {
        return; // the installer manages the firewall rule
    }
    set_text(h, IDC_SU_FW_STATUS, "Checking Windows Firewall…");
    let exe = firewall_exe(h, ctx);
    let hh = h.0 as isize;
    std::thread::spawn(move || post_box(hh, WM_SU_FIREWALL, run_firewall_check(&exe)));
}

/// The elevated step (UAC prompt), then a fresh check once it has finished.
unsafe fn allow_in_firewall(h: HWND, ctx: &Ctx) {
    let exe = firewall_exe(h, ctx);
    let params = wide(&format!(
        "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {}",
        logic::ps_encode(&logic::firewall_allow_script(&exe.to_string_lossy(), ctx.init.port))
    ));
    let ps = wide(&powershell_path().to_string_lossy());
    let mut sei = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        hwnd: h,
        lpVerb: w!("runas"),
        lpFile: PCWSTR(ps.as_ptr()),
        lpParameters: PCWSTR(params.as_ptr()),
        nShow: SW_HIDE.0,
        ..Default::default()
    };
    if ShellExecuteExW(&mut sei).is_err() {
        let e = windows::core::Error::from_thread();
        let cancelled = e.code() == ERROR_CANCELLED.to_hresult();
        set_text(h, IDC_SU_FW_STATUS, if cancelled { "Not changed: the Windows prompt was cancelled." } else { "Could not start the firewall step." });
        return;
    }
    set_text(h, IDC_SU_FW_STATUS, "Updating Windows Firewall…");
    let proc = sei.hProcess.0 as isize;
    let hh = h.0 as isize;
    std::thread::spawn(move || {
        let p = HANDLE(proc as *mut _);
        if !p.is_invalid() {
            WaitForSingleObject(p, 60_000);
            let _ = CloseHandle(p);
        }
        post_box(hh, WM_SU_FIREWALL, run_firewall_check(&exe));
    });
}

unsafe fn start_test(h: HWND, ctx: &mut Ctx) {
    let addr = match logic::normalize_address(&get_text(h, IDC_SU_ADDR)) {
        Ok(a) => a,
        Err(e) => {
            set_text(h, IDC_SU_TEST_RESULT, &e);
            return;
        }
    };
    ctx.test_gen += 1;
    let gen = ctx.test_gen;
    set_text(h, IDC_SU_TEST_RESULT, &format!("Trying {addr}…"));
    enable(h, IDC_SU_TEST, false);
    let hh = h.0 as isize;
    std::thread::spawn(move || {
        let r = match logic::test_reachable(&addr, Duration::from_secs(3)) {
            Ok(sa) => Ok(format!("The Mac answers on port {}. Click Connect.", sa.port())),
            Err(e) => Err(format!(
                "No answer from {addr} ({e}). The network may block PC → Mac connections: the Mac can still connect to this PC if you allow it below."
            )),
        };
        post_box(hh, WM_SU_TESTED, (gen, r, addr));
    });
}

unsafe fn update_this_pc(h: HWND) {
    let addr = get_text(h, IDC_SU_ADDR);
    let toward = logic::normalize_address(&addr).ok();
    let name = std::env::var("COMPUTERNAME").unwrap_or_default();
    let text = match logic::local_ipv4_toward(toward.as_deref()) {
        Some(ip) => format!("This PC's address: {ip}{}. If the Mac can't be reached from here, enter it in Glide Host's setup window on the Mac.", if name.is_empty() { String::new() } else { format!(" ({name})") }),
        None => "This PC's address: not connected to a network.".into(),
    };
    set_text(h, IDC_SU_THIS_PC, &text);
}

unsafe fn sync_enabled(h: HWND) {
    let accept = checked(h, IDC_SU_ACCEPT);
    enable(h, IDC_SU_FIREWALL, accept);
    enable(h, IDC_SU_FW_STATUS, accept);
}

unsafe extern "system" fn dlg_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &mut *(lp.0 as *mut Ctx);
            let _ = SetWindowTextW(h, w!("Glide — Set up"));
            set_text(h, IDC_SU_ADDR, &ctx.init.addr);
            check(h, IDC_SU_ACCEPT, ctx.init.accept);
            check(h, IDC_SU_AUTOSTART, ctx.init.autostart);
            if ctx.init.offer_install {
                check(h, IDC_SU_INSTALL, true);
                set_text(
                    h,
                    IDC_SU_INSTALL_NOTE,
                    &format!("Copies it to {} and adds it to the Start menu. Running from {}.", ctx.init.install_dir.display(), ctx.init.exe.parent().map(|p| p.display().to_string()).unwrap_or_default()),
                );
            } else {
                show(h, IDC_SU_INSTALL, false);
                show(h, IDC_SU_INSTALL_NOTE, false);
            }
            if let Ok(b) = GetDlgItem(Some(h), IDC_SU_FIREWALL) {
                SendMessageW(b, BCM_SETSHIELD, Some(WPARAM(0)), Some(LPARAM(1)));
            }
            if ctx.init.deployed {
                // The installer owns sign-in start and the firewall rule.
                show(h, IDC_SU_AUTOSTART, false);
                show(h, IDC_SU_FIREWALL, false);
                show(h, IDC_SU_FW_STATUS, false);
            }
            let dpi = GetDpiForWindow(h).max(96);
            let big = GetSystemMetricsForDpi(SM_CXICON, dpi);
            let small = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
            if let (Some(ib), Some(is)) = (super::prompt::app_icon(big), super::prompt::app_icon(small)) {
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(ib.0 as isize)));
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(is.0 as isize)));
                if let Ok(ic) = GetDlgItem(Some(h), IDC_SU_ICON) {
                    SendMessageW(ic, STM_SETICON, Some(WPARAM(ib.0 as usize)), None);
                }
                ctx.icons.extend([ib, is]);
            }
            update_this_pc(h);
            sync_enabled(h);
            start_firewall_check(h, ctx);
            if !ctx.init.addr.trim().is_empty() {
                start_test(h, ctx);
            }
            let _ = SetForegroundWindow(h);
            if crate::util::test_hook("GLIDE_SETUP_ANSWER").is_some() || crate::util::test_hook("GLIDE_SETUP_DUMP").is_some() {
                SetTimer(Some(h), HOOK_TIMER, 500, None);
            }
            // Focus the address box (return 0: we set the focus ourselves).
            if let Ok(e) = GetDlgItem(Some(h), IDC_SU_ADDR) {
                let _ = SetFocus(Some(e));
            }
            0
        }
        WM_TIMER if wp.0 == HOOK_TIMER => {
            let _ = KillTimer(Some(h), HOOK_TIMER);
            if let Some(p) = crate::util::test_hook("GLIDE_SETUP_DUMP") {
                match super::prompt::dump_window(h, &p) {
                    Ok((w, hh)) => eprintln!("setup: dumped {w}x{hh} dialog to {p}"),
                    Err(e) => eprintln!("setup: dump failed: {e}"),
                }
            }
            if let Some(a) = crate::util::test_hook("GLIDE_SETUP_ANSWER") {
                let id = if a.trim().eq_ignore_ascii_case("connect") { IDOK.0 } else { IDCANCEL.0 };
                let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(id as usize), LPARAM(0));
            }
            1
        }
        WM_SU_TESTED => {
            let (gen, r, addr) = *Box::from_raw(lp.0 as *mut (u64, Result<String, String>, String));
            if let Some(ctx) = ctx_of(h) {
                enable(h, IDC_SU_TEST, true);
                let current = logic::normalize_address(&get_text(h, IDC_SU_ADDR)).ok();
                if gen == ctx.test_gen && current.as_deref() == Some(addr.as_str()) {
                    set_text(h, IDC_SU_TEST_RESULT, &r.unwrap_or_else(|e| e));
                }
                update_this_pc(h);
            }
            1
        }
        WM_SU_FIREWALL => {
            let st = *Box::from_raw(lp.0 as *mut Option<FirewallStatus>);
            set_text(
                h,
                IDC_SU_FW_STATUS,
                &match st {
                    Some(s) => s.describe(),
                    None => "Couldn't check Windows Firewall. If the Mac can't connect, click Allow.".into(),
                },
            );
            1
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            let code = ((wp.0 >> 16) & 0xFFFF) as u32;
            let Some(ctx) = ctx_of(h) else { return 0 };
            match id {
                IDC_SU_TEST => {
                    start_test(h, ctx);
                    1
                }
                IDC_SU_ADDR if code == EN_CHANGE => {
                    // A result for the old text no longer applies.
                    set_text(h, IDC_SU_TEST_RESULT, "");
                    1
                }
                IDC_SU_ACCEPT => {
                    sync_enabled(h);
                    1
                }
                IDC_SU_INSTALL => {
                    // The rule names the exe: check the one that will run.
                    start_firewall_check(h, ctx);
                    1
                }
                IDC_SU_FIREWALL => {
                    allow_in_firewall(h, ctx);
                    1
                }
                x if x == IDOK.0 => {
                    let text = get_text(h, IDC_SU_ADDR);
                    let accept = checked(h, IDC_SU_ACCEPT);
                    let host = if text.trim().is_empty() {
                        if !accept {
                            set_text(h, IDC_SU_TEST_RESULT, "Enter the Mac's address, or let the Mac connect to this PC.");
                            return 1;
                        }
                        None
                    } else {
                        match logic::normalize_address(&text) {
                            Ok(a) => Some(a),
                            Err(e) => {
                                set_text(h, IDC_SU_TEST_RESULT, &e);
                                if let Ok(c) = GetDlgItem(Some(h), IDC_SU_ADDR) {
                                    let _ = SetFocus(Some(c));
                                }
                                return 1;
                            }
                        }
                    };
                    ctx.choice = Some(Choice {
                        host,
                        accept,
                        autostart: checked(h, IDC_SU_AUTOSTART),
                        install: ctx.init.offer_install && checked(h, IDC_SU_INSTALL),
                    });
                    let _ = EndDialog(h, 1);
                    1
                }
                x if x == IDCANCEL.0 => {
                    let _ = EndDialog(h, 2);
                    1
                }
                _ => 0,
            }
        }
        _ => 0,
    }
}
