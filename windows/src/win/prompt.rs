//! Native password prompt: the `IDD_PASSWORD` dialog from `res/glide.rc` (themed via the
//! manifest, auto DPI-scaled by the dialog manager) with a "Remember on this PC" checkbox.
//!
//! Test hooks (session 0 / SSH, nobody to type): `GLIDE_PROMPT_AUTOFILL=pw` fills the field and
//! presses Connect after ~0.5 s (`GLIDE_PROMPT_AUTOFILL_RETRY` is used instead for later prompts,
//! e.g. after an auth failure); `GLIDE_PROMPT_REMEMBER=1` ticks the box; `GLIDE_PROMPT_DUMP=x.bmp`
//! saves a PrintWindow capture of the dialog first.

use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{CheckDlgButton, IsDlgButtonChecked, BST_CHECKED, BST_UNCHECKED};
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::WindowsAndMessaging::*;

const IDD_PASSWORD: u16 = 101;
const IDC_PW_ICON: i32 = 1000;
const IDC_PW_TEXT: i32 = 1001;
const IDC_PW_EDIT: i32 = 1002;
const IDC_PW_REMEMBER: i32 = 1003;
const AUTOFILL_TIMER: usize = 1;

pub struct Answer {
    pub password: String,
    pub remember: bool,
}

struct Ctx {
    message: String,
    remember: bool,
    answer: Option<Answer>,
    icons: Vec<HICON>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The app icon (resource 1) at `size` px, or None if resources weren't linked in.
pub fn app_icon(size: i32) -> Option<HICON> {
    unsafe {
        let hinst = GetModuleHandleW(None).ok()?;
        LoadImageW(Some(HINSTANCE(hinst.0)), PCWSTR(1 as *const u16), IMAGE_ICON, size, size, LR_DEFAULTCOLOR)
            .ok()
            .map(|h| HICON(h.0))
    }
}

/// Show the password dialog (modal to `owner`). Returns None on Cancel, Err if the dialog
/// resource is missing (caller falls back to a console prompt).
pub fn ask_password(owner: Option<HWND>, message: &str, remember: bool) -> Result<Option<Answer>, String> {
    let mut ctx = Ctx { message: message.to_string(), remember, answer: None, icons: Vec::new() };
    let r = unsafe {
        let hinst = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        DialogBoxParamW(
            Some(HINSTANCE(hinst.0)),
            PCWSTR(IDD_PASSWORD as usize as *const u16),
            owner,
            Some(dlg_proc),
            LPARAM(&mut ctx as *mut Ctx as isize),
        )
    };
    for i in ctx.icons.drain(..) {
        unsafe {
            let _ = DestroyIcon(i);
        }
    }
    if r == -1 {
        return Err(format!("password dialog unavailable: {}", windows::core::Error::from_thread()));
    }
    Ok(ctx.answer)
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
            let _ = SetDlgItemTextW(h, IDC_PW_TEXT, PCWSTR(wide(&ctx.message).as_ptr()));
            let _ = CheckDlgButton(h, IDC_PW_REMEMBER, if ctx.remember { BST_CHECKED } else { BST_UNCHECKED });
            let dpi = GetDpiForWindow(h).max(96);
            let big = GetSystemMetricsForDpi(SM_CXICON, dpi);
            let small = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
            if let (Some(ib), Some(is)) = (app_icon(big), app_icon(small)) {
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_BIG as usize)), Some(LPARAM(ib.0 as isize)));
                SendMessageW(h, WM_SETICON, Some(WPARAM(ICON_SMALL as usize)), Some(LPARAM(is.0 as isize)));
                if let Ok(ic) = GetDlgItem(Some(h), IDC_PW_ICON) {
                    SendMessageW(ic, STM_SETICON, Some(WPARAM(ib.0 as usize)), None);
                }
                ctx.icons.extend([ib, is]);
            }
            let _ = SetForegroundWindow(h);
            if let Ok(e) = GetDlgItem(Some(h), IDC_PW_EDIT) {
                let _ = windows::Win32::UI::Input::KeyboardAndMouse::SetFocus(Some(e));
            }
            static PROMPTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            let n = PROMPTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let fill = std::env::var("GLIDE_PROMPT_AUTOFILL").ok();
            let fill = if n > 0 { std::env::var("GLIDE_PROMPT_AUTOFILL_RETRY").ok().or(fill) } else { fill };
            if let Some(pw) = fill {
                let _ = SetDlgItemTextW(h, IDC_PW_EDIT, PCWSTR(wide(&pw).as_ptr()));
                if std::env::var("GLIDE_PROMPT_REMEMBER").as_deref() == Ok("1") {
                    let _ = CheckDlgButton(h, IDC_PW_REMEMBER, BST_CHECKED);
                }
                SetTimer(Some(h), AUTOFILL_TIMER, 500, None);
            }
            0 // focus set ourselves
        }
        WM_TIMER if wp.0 == AUTOFILL_TIMER => {
            let _ = KillTimer(Some(h), AUTOFILL_TIMER);
            if let Ok(p) = std::env::var("GLIDE_PROMPT_DUMP") {
                match dump_window(h, &p) {
                    Ok((w, hh)) => eprintln!("prompt: dumped {w}x{hh} dialog to {p}"),
                    Err(e) => eprintln!("prompt: dump failed: {e}"),
                }
            }
            let _ = PostMessageW(Some(h), WM_COMMAND, WPARAM(IDOK.0 as usize), LPARAM(0));
            1
        }
        WM_COMMAND => {
            let id = (wp.0 & 0xFFFF) as i32;
            if id == IDOK.0 {
                if let Some(ctx) = ctx_of(h) {
                    let mut buf = vec![0u16; 1024];
                    let n = GetDlgItemTextW(h, IDC_PW_EDIT, &mut buf) as usize;
                    let pw = String::from_utf16_lossy(&buf[..n]);
                    buf.fill(0);
                    if pw.is_empty() {
                        return 1;
                    }
                    ctx.answer = Some(Answer { password: pw, remember: IsDlgButtonChecked(h, IDC_PW_REMEMBER) == BST_CHECKED.0 });
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

/// PrintWindow → 32-bit BMP (test hook).
fn dump_window(h: HWND, path: &str) -> Result<(i32, i32), String> {
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
