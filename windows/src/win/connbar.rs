//! Connection bar glue (UI thread): pointer tracking, hit testing, the hide timer, and telling the
//! renderer what to draw. The state machine is `crate::connbar`; drawing is `Renderer::set_bar`.

use crate::connbar::{tab_rect, ConnBar, Rect};
use std::cell::RefCell;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::{ClientToScreen, ScreenToClient};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Timer id used by the viewer window for the bar (100 ms while it may hide).
pub const BAR_TIMER: usize = 6;

/// Visible tab size (w << 32 | h) as last rasterized by the render thread; 0 = not yet known.
static SIZE: AtomicU64 = AtomicU64::new(0);

struct UiBar {
    bar: ConnBar,
    label: String,
    /// What the renderer currently shows (None = hidden).
    drawn: Option<String>,
    show: Box<dyn Fn(Option<String>)>,
}

thread_local! {
    static BAR: RefCell<Option<UiBar>> = const { RefCell::new(None) };
}

/// UI thread, once. `show(Some(text))` / `show(None)` asks the renderer to draw / hide the tab.
pub fn init(hwnd: HWND, pinned: bool, label: &str, show: Box<dyn Fn(Option<String>)>) {
    BAR.with(|b| *b.borrow_mut() = Some(UiBar { bar: ConnBar::new(pinned), label: label.into(), drawn: None, show }));
    sync(hwnd);
}

/// Render thread: the tab's visible size after rasterizing it.
pub fn set_size(w: u32, h: u32) {
    SIZE.store((w as u64) << 32 | h as u64, Ordering::Relaxed);
}

fn scale(hwnd: HWND) -> f32 {
    unsafe { GetDpiForWindow(hwnd).max(96) as f32 / 96.0 }
}

fn client_w(hwnd: HWND) -> i32 {
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    rc.right - rc.left
}

/// The tab rect in client coordinates (estimated until the renderer reports its size).
pub fn tab(hwnd: HWND) -> Rect {
    let s = SIZE.load(Ordering::Relaxed);
    let sc = scale(hwnd);
    let (w, h) = if s == 0 { ((220.0 * sc) as i32, (26.0 * sc) as i32) } else { ((s >> 32) as i32, (s & 0xFFFF_FFFF) as i32) };
    tab_rect(client_w(hwnd), w, h)
}

fn with<R>(f: impl FnOnce(&mut UiBar) -> R) -> Option<R> {
    BAR.with(|b| b.borrow_mut().as_mut().map(f))
}

/// Push the desired state to the renderer if it changed, and run the timer while needed.
fn sync(hwnd: HWND) {
    let (want, timer) = with(|u| {
        let want = u.bar.visible().then(|| format!("{}{}   ▾", u.label, if u.bar.pinned { "  •" } else { "" }));
        (want, u.bar.visible() && !u.bar.pinned || u.bar.needs_timer())
    })
    .unwrap_or((None, false));
    with(|u| {
        if u.drawn != want {
            u.drawn = want.clone();
            (u.show)(want);
        }
    });
    unsafe {
        if timer {
            SetTimer(Some(hwnd), BAR_TIMER, 100, None);
        } else {
            let _ = KillTimer(Some(hwnd), BAR_TIMER);
        }
    }
}

/// WM_MOUSEMOVE at client (x, y). Returns true if the pointer is over the tab: don't forward it.
/// While a mouse button is held (a drag on the Mac) the bar neither appears nor captures input.
pub fn on_mouse_move(hwnd: HWND, x: i32, y: i32, buttons_down: bool) -> bool {
    if buttons_down {
        return false;
    }
    let t = tab(hwnd);
    let (cw, sc) = (client_w(hwnd), scale(hwnd));
    let hit = with(|u| {
        u.bar.pointer(Some((x, y)), cw, t, sc, Instant::now());
        u.bar.hit((x, y), t)
    })
    .unwrap_or(false);
    sync(hwnd);
    hit
}

/// Is client point (x, y) on the visible tab?
pub fn hit(hwnd: HWND, x: i32, y: i32) -> bool {
    let t = tab(hwnd);
    with(|u| u.bar.hit((x, y), t)).unwrap_or(false)
}

/// Is the mouse pointer (screen position) on the visible tab?
pub fn cursor_hit(hwnd: HWND) -> bool {
    unsafe {
        let mut p = POINT::default();
        if GetCursorPos(&mut p).is_err() || !ScreenToClient(hwnd, &mut p).as_bool() {
            return false;
        }
        hit(hwnd, p.x, p.y)
    }
}

/// BAR_TIMER: poll the pointer (it may have left the window) and hide when due.
pub fn on_timer(hwnd: HWND) {
    // Pointer in client coordinates, or None if it isn't over this window.
    let p = unsafe {
        let mut sp = POINT::default();
        if GetCursorPos(&mut sp).is_ok() && WindowFromPoint(sp) == hwnd {
            let mut cp = sp;
            ScreenToClient(hwnd, &mut cp).as_bool().then_some((cp.x, cp.y))
        } else {
            None
        }
    };
    let t = tab(hwnd);
    let (cw, sc) = (client_w(hwnd), scale(hwnd));
    with(|u| {
        let now = Instant::now();
        u.bar.pointer(p, cw, t, sc, now);
        u.bar.tick(now);
    });
    sync(hwnd);
}

/// Keep the bar up while the menu is open / let it hide afterwards.
pub fn hold(hwnd: HWND) {
    with(|u| u.bar.hold());
    sync(hwnd);
}
pub fn release(hwnd: HWND) {
    with(|u| u.bar.release(Instant::now()));
    sync(hwnd);
}

/// Show it briefly (test hook / keyboard-opened menu).
pub fn reveal(hwnd: HWND) {
    with(|u| u.bar.reveal(Instant::now()));
    sync(hwnd);
}

pub fn pinned() -> bool {
    with(|u| u.bar.pinned).unwrap_or(false)
}

pub fn set_pinned(hwnd: HWND, pinned: bool) {
    with(|u| {
        u.bar.pinned = pinned;
        if !pinned {
            u.bar.reveal(Instant::now()); // fade away normally instead of vanishing under the pointer
        }
    });
    sync(hwnd);
}

/// The tab text (host name / status).
pub fn set_label(hwnd: HWND, label: &str) {
    with(|u| u.label = label.to_string());
    sync(hwnd);
}

/// Screen point just below the tab's bottom center (menu anchor).
pub fn menu_anchor(hwnd: HWND) -> POINT {
    let t = tab(hwnd);
    let mut p = POINT { x: t.x + t.w / 2, y: t.y + t.h };
    unsafe {
        let _ = ClientToScreen(hwnd, &mut p);
    }
    p
}
