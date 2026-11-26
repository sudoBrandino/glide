//! Native pairing prompt (security v2, docs/PROTOCOL.md §2.4): the `IDD_PAIR` dialog from
//! `res/glide.rc` (themed via the manifest, auto DPI-scaled by the dialog manager) showing the
//! 6-digit code in a large font. The user compares it with the code on the Mac and clicks
//! "Codes Match — Pair" (or Cancel). The dialog closes by itself when the host ends the pairing
//! (`cancel` flag, polled).
//!
//! A pairing request can arrive while the user is typing (into the Mac through this viewer, or in
//! another app), so a stray Return or Space must never confirm it:
//! - Cancel is the default button and has the focus;
//! - "Codes Match — Pair" stays disabled for `CONFIRM_DELAY_MS` after the dialog appears, and
//!   again each time it is activated from the keyboard;
//! - the dialog doesn't force itself to the foreground over another app: if it isn't the
//!   foreground window, its taskbar button flashes until the user switches to it.
//!
//! Test hooks (session 0 / SSH, nobody to click; `test-hooks` builds only, see
//! `util::test_hook`): `GLIDE_PAIR_CONFIRM=yes|no` presses the button once it is enabled;
//! `GLIDE_PROMPT_DUMP=x.bmp` saves a PrintWindow capture of the dialog first.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, GetFocus, IsWindowEnabled, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_PAIR: u16 = 102;
const IDC_PAIR_ICON: i32 = 1100;
const IDC_PAIR_TEXT: i32 = 1101;
const IDC_PAIR_CODE: i32 = 1102;
const IDC_PAIR_DETAIL: i32 = 1103;
const AUTOFILL_TIMER: usize = 1;
const POLL_TIMER: usize = 2;
/// Enables "Codes Match — Pair" `CONFIRM_DELAY_MS` after the dialog appears (or is activated).
const ARM_TIMER: usize = 3;
/// Shortly after the dialog is shown: flash the taskbar button if it isn't in the foreground.
const FLASH_TIMER: usize = 4;
const CONFIRM_DELAY_MS: u32 = 1000;

/// What the pairing dialog shows.
pub struct PairText {
    /// Headline, e.g. "Pair this PC with the Mac at 192.168.50.4:7420?"
    pub text: String,
    /// "123 456"
    pub code: String,
    /// Fingerprints + instructions.
    pub detail: String,
}

/// The same dialog for other confirmations (managed-mode approval, organization sign-in): the
/// labels, the size of the big middle line, and what the confirm button does.
pub struct PromptSpec {
    pub title: String,
    pub t: PairText,
    pub confirm: String,
    pub cancel: String,
    /// Point size of the big middle line (`code`).
    pub code_pt: i32,
    /// Some: the confirm button runs this and the dialog stays open (e.g. "Open browser again").
    pub on_confirm: Option<Box<dyn Fn()>>,
    /// Updates the middle line while open (polled every 200 ms), e.g. a countdown.
    pub live_code: Option<Box<dyn Fn() -> String>>,
}

struct Ctx {
    t: PairText,
    title: String,
    cancel: Arc<AtomicBool>,
    answer: bool,
    icons: Vec<HICON>,
    font: Option<HFONT>,
    confirm_label: String,
    cancel_label: String,
    code_pt: i32,
    on_confirm: Option<Box<dyn Fn()>>,
    live_code: Option<Box<dyn Fn() -> String>>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The app icon (resource 1) at `size` px, or None if resources weren't linked in.
pub fn app_icon(size: i32) -> Option<HICON> {
    unsafe {
        let hinst = GetModuleHandleW(None).ok()?;
        // MAKEINTRESOURCE(1): an integer resource id in a pointer, never dereferenced as memory.
        LoadImageW(Some(HINSTANCE(hinst.0)), PCWSTR(std::ptr::without_provenance(1)), IMAGE_ICON, size, size, LR_DEFAULTCOLOR)
            .ok()
            .map(|h| HICON(h.0))
    }
}

/// Show the pairing dialog (modal to `owner`). Ok(true) = the user says the codes match.
/// Returns Ok(false) on Cancel or when `cancel` is set (the host ended the pairing).
/// Err if the dialog resource is missing.
pub fn ask_pairing(owner: Option<HWND>, t: PairText, cancel: Arc<AtomicBool>) -> Result<bool, String> {
    ask_pairing_titled(owner, t, cancel, "Glide — Pair with Mac")
}

/// `ask_pairing` with another window title (the Windows host's prompt pairs with a Mac viewer).
pub fn ask_pairing_titled(owner: Option<HWND>, t: PairText, cancel: Arc<AtomicBool>, title: &str) -> Result<bool, String> {
    let spec = PromptSpec {
        title: title.to_string(),
        t,
        confirm: "Codes Match — Pair".into(),
        cancel: "Cancel".into(),
        code_pt: 30,
        on_confirm: None,
        live_code: None,
    };
    ask(owner, spec, cancel)
}

/// Shows `spec` in the pairing dialog's layout (Cancel default, confirm enabled after 1 s, no
/// focus stealing, closes when `cancel` is set). Ok(true) = confirmed.
pub fn ask(owner: Option<HWND>, spec: PromptSpec, cancel: Arc<AtomicBool>) -> Result<bool, String> {
    if cancel.load(Ordering::SeqCst) {
        return Ok(false);
    }
    let mut ctx = Ctx {
        t: spec.t,
        title: spec.title,
        cancel,
        answer: false,
        icons: Vec::new(),
        font: None,
        confirm_label: spec.confirm,
        cancel_label: spec.cancel,
        code_pt: spec.code_pt,
        on_confirm: spec.on_confirm,
        live_code: spec.live_code,
    };
    let r = unsafe {
        let hinst = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        DialogBoxParamW(Some(HINSTANCE(hinst.0)), PCWSTR(IDD_PAIR as usize as *const u16), owner, Some(dlg_proc), LPARAM(&mut ctx as *mut Ctx as isize))
    };
    unsafe {
        for i in ctx.icons.drain(..) {
            let _ = DestroyIcon(i);
        }
        if let Some(f) = ctx.font.take() {
            let _ = DeleteObject(f.into());
        }
    }
    if r == -1 {
        return Err(format!("pairing dialog unavailable: {}", windows::core::Error::from_thread()));
    }
    Ok(ctx.answer && !ctx.cancel.load(Ordering::SeqCst))
}

unsafe fn ctx_of(h: HWND) -> Option<&'static mut Ctx> {
    let p = GetWindowLongPtrW(h, GWLP_USERDATA) as *mut Ctx;
    p.as_mut()
}

/// Disable "Codes Match — Pair" for `CONFIRM_DELAY_MS` (ARM_TIMER enables it again), keeping
/// the focus on Cancel.
unsafe fn guard_confirm(h: HWND) {
    if let Ok(ok) = GetDlgItem(Some(h), IDOK.0) {
        if GetFocus() == ok {
            if let Ok(c) = GetDlgItem(Some(h), IDCANCEL.0) {
                let _ = SetFocus(Some(c));
            }
        }
        let _ = EnableWindow(ok, false);
    }
    SetTimer(Some(h), ARM_TIMER, CONFIRM_DELAY_MS, None);
}

/// "Codes Match — Pair" is enabled (only then does IDOK count, whatever sent it).
unsafe fn confirm_enabled(h: HWND) -> bool {
    GetDlgItem(Some(h), IDOK.0).is_ok_and(|ok| IsWindowEnabled(ok).as_bool())
}

unsafe extern "system" fn dlg_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &mut *(lp.0 as *mut Ctx);
            let _ = SetWindowTextW(h, PCWSTR(wide(&ctx.title).as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_TEXT, PCWSTR(wide(&ctx.t.text).as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_CODE, PCWSTR(wide(&ctx.t.code).as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_DETAIL, PCWSTR(wide(&ctx.t.detail).as_ptr()));
            let _ = SetDlgItemTextW(h, IDOK.0, PCWSTR(wide(&ctx.confirm_label).as_ptr()));
            let _ = SetDlgItemTextW(h, IDCANCEL.0, PCWSTR(wide(&ctx.cancel_label).as_ptr()));
            let dpi = GetDpiForWindow(h).max(96);
            // The code: large, monospaced digits.
            let font = CreateFontW(
                -((ctx.code_pt * dpi as i32) / 72),
                0,
                0,
                0,
                FW_SEMIBOLD.0 as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY,
                FIXED_PITCH.0 as u32,
                PCWSTR(wide("Consolas").as_ptr()),
            );
            if !font.is_invalid() {
                if let Ok(c) = GetDlgItem(Some(h), IDC_PAIR_CODE) {
                    SendMessageW(c, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
                }
                ctx.font = Some(font);
            }
            let big = GetSystemMetricsForDpi(SM_CXICON, dpi);
            let small = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
            if let (Some(ib), Some(is)) = (app_icon(big), app_icon(small)) {
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(ib.0 as isize)));
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(is.0 as isize)));
                if let Ok(ic) = GetDlgItem(Some(h), IDC_PAIR_ICON) {
                    SendMessageW(ic, STM_SETICON, Some(WPARAM(ib.0 as usize)), None);
                }
                ctx.icons.extend([ib, is]);
            }
            // Cancel is the default button (also in res/glide.rc) and gets the focus; the confirm
            // button starts disabled. No SetForegroundWindow (nor DS_SETFOREGROUND): FLASH_TIMER
            // flashes the taskbar button instead when another app has the foreground.
            SendMessageW(h, DM_SETDEFID, Some(WPARAM(IDCANCEL.0 as usize)), None);
            guard_confirm(h);
            SetTimer(Some(h), FLASH_TIMER, 150, None);
            SetTimer(Some(h), POLL_TIMER, 200, None);
            if crate::util::test_hook("GLIDE_PAIR_CONFIRM").is_some() {
                SetTimer(Some(h), AUTOFILL_TIMER, CONFIRM_DELAY_MS + 300, None);
            }
            if let Ok(c) = GetDlgItem(Some(h), IDCANCEL.0) {
                let _ = SetFocus(Some(c));
            }
            0 // we set the focus ourselves (Cancel)
        }
        WM_ACTIVATE if (wp.0 & 0xFFFF) as u32 == WA_ACTIVE => {
            // Activated from the keyboard (Alt+Tab, or the system handing it the focus): the user
            // may be mid-keystroke, so hold the confirm button off again. A mouse click
            // (WA_CLICKACTIVE) is deliberate and isn't delayed.
            guard_confirm(h);
            // Default processing restores the saved focus; then put it on Cancel.
            if let Ok(c) = GetDlgItem(Some(h), IDCANCEL.0) {
                let _ = PostMessageW(Some(h), WM_NEXTDLGCTL, WPARAM(c.0 as usize), LPARAM(1));
            }
            0
        }
        WM_TIMER if wp.0 == ARM_TIMER => {
            let _ = KillTimer(Some(h), ARM_TIMER);
            if let Ok(ok) = GetDlgItem(Some(h), IDOK.0) {
                let _ = EnableWindow(ok, true);
            }
            1
        }
        WM_TIMER if wp.0 == FLASH_TIMER => {
            let _ = KillTimer(Some(h), FLASH_TIMER);
            if GetForegroundWindow() != h {
                let fi = FLASHWINFO {
                    cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                    hwnd: h,
                    dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                    uCount: 0,
                    dwTimeout: 0,
                };
                let _ = FlashWindowEx(&fi);
            }
            1
        }
        WM_TIMER if wp.0 == POLL_TIMER => {
            if let Some(c) = ctx_of(h) {
                if c.cancel.load(Ordering::SeqCst) {
                    let _ = EndDialog(h, 2);
                } else if let Some(f) = &c.live_code {
                    let _ = SetDlgItemTextW(h, IDC_PAIR_CODE, PCWSTR(wide(&f()).as_ptr()));
                }
            }
            1
        }
        WM_TIMER if wp.0 == AUTOFILL_TIMER => {
            let _ = KillTimer(Some(h), AUTOFILL_TIMER);
            if let Some(p) = crate::util::test_hook("GLIDE_PROMPT_DUMP") {
                match dump_window(h, &p) {
                    Ok((w, hh)) => eprintln!("prompt: dumped {w}x{hh} dialog to {p}"),
                    Err(e) => eprintln!("prompt: dump failed: {e}"),
                }
            }
            let yes = crate::util::test_hook("GLIDE_PAIR_CONFIRM").is_some_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "y" | "yes"));
            eprintln!("prompt: GLIDE_PAIR_CONFIRM -> {}", if yes { "Codes Match" } else { "Cancel" });
            if yes && !confirm_enabled(h) {
                // Activated again meanwhile: try once the button is enabled.
                SetTimer(Some(h), AUTOFILL_TIMER, CONFIRM_DELAY_MS + 300, None);
                return 1;
            }
            let id = if yes { IDOK.0 } else { IDCANCEL.0 };
            let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(id as usize), LPARAM(0));
            1
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            if id == IDOK.0 {
                if !confirm_enabled(h) {
                    return 1; // still held off: ignore, whatever sent it
                }
                if let Some(ctx) = ctx_of(h) {
                    if let Some(f) = &ctx.on_confirm {
                        f();
                        return 1;
                    }
                    ctx.answer = true;
                }
                let _ = EndDialog(h, 1);
                1
            } else if id == IDCANCEL.0 {
                let _ = EndDialog(h, 2);
                1
            } else {
                0
            }
        }
        _ => 0,
    }
}

/// PrintWindow → 32-bit BMP (test hook; also the setup dialog's).
pub(super) fn dump_window(h: HWND, path: &str) -> Result<(i32, i32), String> {
    unsafe {
        let mut rc = RECT::default();
        GetWindowRect(h, &mut rc).map_err(|e| e.to_string())?;
        let (w, hh) = (rc.right - rc.left, rc.bottom - rc.top);
        let screen = GetDC(None);
        let dc = CreateCompatibleDC(Some(screen));
        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -hh,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut std::ffi::c_void = std::ptr::null_mut();
        let bmp = CreateDIBSection(Some(dc), &bmi, DIB_RGB_COLORS, &mut bits, None, 0).map_err(|e| e.to_string())?;
        let old = SelectObject(dc, bmp.into());
        let mut ok = PrintWindow(h, dc, PRINT_WINDOW_FLAGS(0)).as_bool();
        let _ = GdiFlush();
        let blank = |b: *mut std::ffi::c_void| std::slice::from_raw_parts(b as *const u32, (w * hh) as usize).iter().all(|&p| p & 0xFF_FFFF == 0);
        if !ok || blank(bits) {
            // Session 0 (no DWM): ask the window to paint itself.
            const PRF: isize = 0x2 | 0x4 | 0x8 | 0x10; // NONCLIENT | CLIENT | ERASEBKGND | CHILDREN
            SendMessageW(h, WM_PRINT, Some(WPARAM(dc.0 as usize)), Some(LPARAM(PRF)));
            let _ = GdiFlush();
            ok = !blank(bits);
        }
        let px = std::slice::from_raw_parts(bits as *const u8, (w * hh * 4) as usize).to_vec();
        SelectObject(dc, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(dc);
        ReleaseDC(None, screen);
        if !ok {
            return Err("PrintWindow failed".into());
        }
        let mut out = Vec::with_capacity(54 + px.len());
        out.extend_from_slice(b"BM");
        out.extend_from_slice(&(54 + px.len() as u32).to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&54u32.to_le_bytes());
        out.extend_from_slice(&40u32.to_le_bytes());
        out.extend_from_slice(&w.to_le_bytes());
        out.extend_from_slice(&(-hh).to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&32u16.to_le_bytes());
        out.extend_from_slice(&[0u8; 24]);
        out.extend_from_slice(&px);
        std::fs::write(path, out).map_err(|e| e.to_string())?;
        Ok((w, hh))
    }
}
