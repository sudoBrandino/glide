//! Native pairing prompt (security v2, docs/PROTOCOL.md §2.4): the `IDD_PAIR` dialog from
//! `res/glide.rc` (themed via the manifest, auto DPI-scaled by the dialog manager) showing the
//! 6-digit code in a large font. The user compares it with the code on the Mac and clicks
//! "Codes Match — Pair" (or Cancel). The dialog closes by itself when the host ends the pairing
//! (`cancel` flag, polled).
//!
//! Test hooks (session 0 / SSH, nobody to click): `GLIDE_PAIR_CONFIRM=yes|no` presses the
//! button after ~0.5 s; `GLIDE_PROMPT_DUMP=x.bmp` saves a PrintWindow capture of the dialog first.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_PAIR: u16 = 102;
const IDC_PAIR_ICON: i32 = 1100;
const IDC_PAIR_TEXT: i32 = 1101;
const IDC_PAIR_CODE: i32 = 1102;
const IDC_PAIR_DETAIL: i32 = 1103;
const AUTOFILL_TIMER: usize = 1;
const POLL_TIMER: usize = 2;

/// What the pairing dialog shows.
pub struct PairText {
    /// Headline, e.g. "Pair this PC with the Mac at 192.168.50.4:7420?"
    pub text: String,
    /// "123 456"
    pub code: String,
    /// Fingerprints + instructions.
    pub detail: String,
}

struct Ctx {
    t: PairText,
    cancel: Arc<AtomicBool>,
    answer: bool,
    icons: Vec<HICON>,
    font: Option<HFONT>,
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
    if cancel.load(Ordering::SeqCst) {
        return Ok(false);
    }
    let mut ctx = Ctx { t, cancel, answer: false, icons: Vec::new(), font: None };
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

unsafe extern "system" fn dlg_proc(h: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> isize {
    match msg {
        WM_INITDIALOG => {
            SetWindowLongPtrW(h, GWLP_USERDATA, lp.0);
            let ctx = &mut *(lp.0 as *mut Ctx);
            let _ = SetWindowTextW(h, PCWSTR(wide("Glide — Pair with Mac").as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_TEXT, PCWSTR(wide(&ctx.t.text).as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_CODE, PCWSTR(wide(&ctx.t.code).as_ptr()));
            let _ = SetDlgItemTextW(h, IDC_PAIR_DETAIL, PCWSTR(wide(&ctx.t.detail).as_ptr()));
            let _ = SetDlgItemTextW(h, IDOK.0, PCWSTR(wide("Codes Match — Pair").as_ptr()));
            let dpi = GetDpiForWindow(h).max(96);
            // The code: large, monospaced digits.
            let font = CreateFontW(
                -((30 * dpi as i32) / 72),
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
            let _ = SetForegroundWindow(h);
            SetTimer(Some(h), POLL_TIMER, 200, None);
            if std::env::var("GLIDE_PAIR_CONFIRM").is_ok() {
                SetTimer(Some(h), AUTOFILL_TIMER, 500, None);
            }
            1 // default focus (the "Codes Match" button)
        }
        WM_TIMER if wp.0 == POLL_TIMER => {
            if ctx_of(h).is_some_and(|c| c.cancel.load(Ordering::SeqCst)) {
                let _ = EndDialog(h, 2);
            }
            1
        }
        WM_TIMER if wp.0 == AUTOFILL_TIMER => {
            let _ = KillTimer(Some(h), AUTOFILL_TIMER);
            if let Ok(p) = std::env::var("GLIDE_PROMPT_DUMP") {
                match dump_window(h, &p) {
                    Ok((w, hh)) => eprintln!("prompt: dumped {w}x{hh} dialog to {p}"),
                    Err(e) => eprintln!("prompt: dump failed: {e}"),
                }
            }
            let yes = std::env::var("GLIDE_PAIR_CONFIRM").is_ok_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "y" | "yes"));
            eprintln!("prompt: GLIDE_PAIR_CONFIRM -> {}", if yes { "Codes Match" } else { "Cancel" });
            let id = if yes { IDOK.0 } else { IDCANCEL.0 };
            let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(id as usize), LPARAM(0));
            1
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            if id == IDOK.0 {
                if let Some(ctx) = ctx_of(h) {
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
