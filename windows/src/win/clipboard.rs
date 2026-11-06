//! Windows clipboard I/O for clipboard sync (docs/PROTOCOL.md §5).
//!
//! - UI thread: `AddClipboardFormatListener` on the viewer window; on `WM_CLIPBOARDUPDATE` read
//!   CF_UNICODETEXT, else the registered "PNG" format, else CF_DIB (raw bytes only, quick), and
//!   apply received clipboards with `OpenClipboard`/`SetClipboardData` (CF_UNICODETEXT, "PNG",
//!   CF_DIB). `EchoGuard` (sequence number + content hash) lives here, UI-thread only.
//! - Worker thread (`glide-clip`): DIB -> PNG encoding and sending (a 16 MiB send must not block
//!   the UI thread), and PNG -> DIB preparation of received images.
//! - Receiver thread: `enable` on ClipboardCaps, `incoming` on Clipboard.
//!
//! Sync is active only while a connection is up and the host has sent ClipboardCaps.

use crate::clipboard::{prepare_incoming, privacy_marker, utf16_to_wire, EchoGuard, LocalClip, Prepared, PRIVACY_FORMATS};
use crate::net::Sender;
use crate::protocol::{ClientMsg, ClipboardData, CLIPBOARD_MAX_BYTES, CLIP_CAPS_PNG, CLIP_CAPS_TEXT};
use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, Ordering};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::Duration;
use windows::core::w;
use windows::Win32::Foundation::*;
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// Posted to the viewer window when a prepared incoming clipboard is ready to apply.
pub const WM_APP_CLIPBOARD: u32 = WM_APP + 0x50;
const READ_TIMER: usize = 0x50;
const APPLY_TIMER: usize = 0x51;
const MAX_TRIES: u32 = 10;

const CF_UNICODETEXT: u32 = 13;
const CF_DIB: u32 = 8;
/// Don't copy clipboard blobs bigger than this (8K RGBA DIB ~ 133 MB).
const MAX_READ_BYTES: usize = 160 << 20;

struct Peer {
    sender: Sender,
    max_bytes: usize,
    formats: u32,
    generation: u32,
}

enum Job {
    Outgoing { clip: LocalClip, seq: u32, max_bytes: usize, generation: u32 },
    Incoming(ClipboardData),
}

struct Clip {
    peer: Mutex<Option<Peer>>,
    pending: Mutex<Option<Prepared>>,
    jobs: Mutex<mpsc::Sender<Job>>,
    hwnd: AtomicIsize,
    png_format: u32,
    /// (name, registered id) of the clipboard privacy markers.
    privacy_formats: Vec<(&'static str, u32)>,
    seq: AtomicU32,
    generation: AtomicU32,
}

static CLIP: OnceLock<Clip> = OnceLock::new();

/// `--clipboard-sync-secrets` / GLIDE_CLIPBOARD_SYNC_SECRETS=1: also send content marked private
/// by its source app (password managers). Default false. (Moves to config.json later.)
static SYNC_SECRETS: AtomicBool = AtomicBool::new(false);

pub fn set_sync_secrets(on: bool) {
    SYNC_SECRETS.store(on, Ordering::Relaxed);
}

#[derive(Default)]
struct UiClip {
    guard: EchoGuard,
    read_tries: u32,
    apply_tries: u32,
}

thread_local! {
    static UI: RefCell<UiClip> = RefCell::new(UiClip::default());
}

/// UI thread, once, after the window exists.
pub fn init(hwnd: HWND) {
    let (tx, rx) = mpsc::channel::<Job>();
    let png_format = unsafe { RegisterClipboardFormatW(w!("PNG")) };
    let clip = Clip {
        peer: Mutex::new(None),
        pending: Mutex::new(None),
        jobs: Mutex::new(tx),
        hwnd: AtomicIsize::new(hwnd.0 as isize),
        png_format,
        privacy_formats: PRIVACY_FORMATS
            .iter()
            .map(|&n| {
                let wide: Vec<u16> = n.encode_utf16().chain(std::iter::once(0)).collect();
                (n, unsafe { RegisterClipboardFormatW(windows::core::PCWSTR(wide.as_ptr())) })
            })
            .collect(),
        seq: AtomicU32::new(0),
        generation: AtomicU32::new(0),
    };
    if CLIP.set(clip).is_err() {
        return;
    }
    if let Err(e) = std::thread::Builder::new().name("glide-clip".into()).spawn(move || worker(rx)) {
        eprintln!("clipboard: worker thread failed: {e}");
        return;
    }
    // Track the sequence number from the start: only changes made during a session are sent.
    UI.with(|u| u.borrow_mut().guard.baseline(unsafe { GetClipboardSequenceNumber() } as u64));
    if let Err(e) = unsafe { AddClipboardFormatListener(hwnd) } {
        eprintln!("clipboard: AddClipboardFormatListener failed: {e}");
    }
}

pub fn shutdown(hwnd: HWND) {
    disable();
    unsafe {
        let _ = RemoveClipboardFormatListener(hwnd);
    }
}

/// Receiver thread: the host sent ClipboardCaps on this connection.
pub fn enable(sender: Sender, formats: u32, max_bytes: u32) {
    let Some(c) = CLIP.get() else { return };
    let generation = c.generation.fetch_add(1, Ordering::Relaxed) + 1;
    let max_bytes = (max_bytes as usize).min(CLIPBOARD_MAX_BYTES);
    eprintln!("clipboard: sync on (host formats {formats:#x}, max {max_bytes} bytes)");
    *c.peer.lock().unwrap() = Some(Peer { sender, max_bytes, formats, generation });
}

/// Session thread: the connection ended.
pub fn disable() {
    let Some(c) = CLIP.get() else { return };
    c.generation.fetch_add(1, Ordering::Relaxed);
    *c.peer.lock().unwrap() = None;
    *c.pending.lock().unwrap() = None;
}

/// Receiver thread: a Clipboard message from the host.
pub fn incoming(data: ClipboardData) {
    let Some(c) = CLIP.get() else { return };
    if c.peer.lock().unwrap().is_none() {
        return; // host didn't negotiate (§5): ignore
    }
    let _ = c.jobs.lock().unwrap().send(Job::Incoming(data));
}

pub fn is_timer(id: usize) -> bool {
    id == READ_TIMER || id == APPLY_TIMER
}

pub fn on_timer(hwnd: HWND, id: usize) {
    unsafe {
        let _ = KillTimer(Some(hwnd), id);
    }
    match id {
        READ_TIMER => read_and_send(hwnd),
        APPLY_TIMER => apply_pending(hwnd),
        _ => {}
    }
}

/// UI thread: WM_CLIPBOARDUPDATE.
pub fn on_clipboard_update(hwnd: HWND) {
    let Some(c) = CLIP.get() else { return };
    let marker = unsafe { GetClipboardSequenceNumber() } as u64;
    if !UI.with(|u| u.borrow_mut().guard.changed(marker)) {
        return; // our own write (or nothing new)
    }
    if unsafe { GetClipboardOwner() }.ok().map(|o| o.0) == Some(hwnd.0) {
        return; // our own write
    }
    if c.peer.lock().unwrap().is_none() {
        return;
    }
    UI.with(|u| u.borrow_mut().read_tries = 0);
    read_and_send(hwnd);
}

fn retry(hwnd: HWND, timer: usize, tries: u32, what: &str) {
    if tries < MAX_TRIES {
        unsafe {
            SetTimer(Some(hwnd), timer, 30, None);
        }
    } else {
        eprintln!("clipboard: {what}: clipboard stayed locked by another app, giving up");
    }
}

fn read_and_send(hwnd: HWND) {
    let Some(c) = CLIP.get() else { return };
    let Some((formats, max_bytes, generation)) = c.peer.lock().unwrap().as_ref().map(|p| (p.formats, p.max_bytes, p.generation))
    else {
        return;
    };
    if unsafe { OpenClipboard(Some(hwnd)) }.is_err() {
        let tries = UI.with(|u| {
            let mut u = u.borrow_mut();
            u.read_tries += 1;
            u.read_tries
        });
        return retry(hwnd, READ_TIMER, tries, "read");
    }
    let clip = unsafe { read_open_clipboard(c, formats, SYNC_SECRETS.load(Ordering::Relaxed)) };
    let marker = unsafe { GetClipboardSequenceNumber() } as u64;
    unsafe {
        let _ = CloseClipboard();
    }
    let clip = match clip {
        Ok(Some(clip)) => clip,
        Ok(None) => return,
        Err(why) => return eprintln!("clipboard: {why}"),
    };
    if !UI.with(|u| u.borrow_mut().guard.should_send(clip.hash(), marker)) {
        return; // same content as last sent/applied
    }
    let seq = c.seq.fetch_add(1, Ordering::Relaxed).wrapping_add(1).max(1);
    let _ = c.jobs.lock().unwrap().send(Job::Outgoing { clip, seq, max_bytes, generation });
}

/// Copy a clipboard format's HGLOBAL contents. Clipboard must be open.
unsafe fn read_global(fmt: u32) -> Option<Vec<u8>> {
    if IsClipboardFormatAvailable(fmt).is_err() {
        return None;
    }
    let h = GetClipboardData(fmt).ok()?;
    let hg = HGLOBAL(h.0);
    let size = GlobalSize(hg);
    if size == 0 {
        return None;
    }
    if size > MAX_READ_BYTES {
        eprintln!("clipboard: local clipboard item is {} MiB, not sent", size >> 20);
        return None;
    }
    let p = GlobalLock(hg) as *const u8;
    if p.is_null() {
        return None;
    }
    let v = std::slice::from_raw_parts(p, size).to_vec();
    let _ = GlobalUnlock(hg);
    Some(v)
}

/// Privacy marker on the open clipboard, if any (pure decision in `clipboard::privacy_marker`).
unsafe fn open_clipboard_privacy_marker(c: &Clip) -> Option<&'static str> {
    let present: Vec<(&str, Option<u32>)> = c
        .privacy_formats
        .iter()
        .filter(|&&(_, id)| id != 0 && IsClipboardFormatAvailable(id).is_ok())
        .map(|&(name, id)| (name, read_global(id).filter(|b| b.len() >= 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))))
        .collect();
    privacy_marker(&present)
}

/// Text (if non-empty) wins; else PNG, else DIB (§5 sender rules). Err = not sent, with the reason
/// (never the content). Clipboard must be open.
unsafe fn read_open_clipboard(c: &Clip, formats: u32, sync_secrets: bool) -> Result<Option<LocalClip>, String> {
    if !sync_secrets {
        if let Some(m) = open_clipboard_privacy_marker(c) {
            return Err(format!("local content is marked private ({m}), not sent (--clipboard-sync-secrets to sync it)"));
        }
    }
    Ok(read_content(c.png_format, formats))
}

unsafe fn read_content(png_format: u32, formats: u32) -> Option<LocalClip> {
    if formats & CLIP_CAPS_TEXT != 0 {
        if let Some(b) = read_global(CF_UNICODETEXT) {
            let units: Vec<u16> = b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
            let text = utf16_to_wire(&units);
            if !text.is_empty() {
                return Some(LocalClip::Text(text));
            }
        }
    }
    if formats & CLIP_CAPS_PNG != 0 {
        if png_format != 0 {
            if let Some(b) = read_global(png_format) {
                let n = crate::clipboard::png_trim(&b).len();
                let mut b = b;
                b.truncate(n);
                return Some(LocalClip::Png(b));
            }
        }
        if let Some(b) = read_global(CF_DIB) {
            return Some(LocalClip::Dib(b));
        }
    }
    None
}

/// UI thread: WM_APP_CLIPBOARD.
pub fn on_app_clipboard(hwnd: HWND) {
    UI.with(|u| u.borrow_mut().apply_tries = 0);
    apply_pending(hwnd);
}

fn apply_pending(hwnd: HWND) {
    let Some(c) = CLIP.get() else { return };
    if c.pending.lock().unwrap().is_none() {
        return;
    }
    if unsafe { OpenClipboard(Some(hwnd)) }.is_err() {
        let tries = UI.with(|u| {
            let mut u = u.borrow_mut();
            u.apply_tries += 1;
            u.apply_tries
        });
        return retry(hwnd, APPLY_TIMER, tries, "apply");
    }
    let Some(p) = c.pending.lock().unwrap().take() else {
        unsafe {
            let _ = CloseClipboard();
        }
        return;
    };
    if !UI.with(|u| u.borrow().guard.should_apply(p.hash, unsafe { GetClipboardSequenceNumber() } as u64)) {
        unsafe {
            let _ = CloseClipboard();
        }
        eprintln!("clipboard <- host: same content as the local clipboard (seq {}), kept as is", p.seq);
        return;
    }
    let mut ok = unsafe { EmptyClipboard() }.is_ok();
    unsafe {
        if let Some(t) = &p.text_utf16 {
            ok &= set_global(CF_UNICODETEXT, std::slice::from_raw_parts(t.as_ptr() as *const u8, t.len() * 2));
        }
        if let Some(png) = &p.png {
            if c.png_format != 0 {
                ok &= set_global(c.png_format, png);
            }
        }
        if let Some(dib) = &p.dib {
            ok &= set_global(CF_DIB, dib);
        }
        let _ = CloseClipboard();
    }
    let marker = unsafe { GetClipboardSequenceNumber() } as u64;
    UI.with(|u| u.borrow_mut().guard.did_apply(p.hash, marker));
    let what = match (&p.text_utf16, &p.png) {
        (Some(t), _) => format!("text, {} UTF-16 units", t.len().saturating_sub(1)),
        (None, Some(png)) => format!("image, {} bytes PNG", png.len()),
        _ => "nothing".into(),
    };
    if ok {
        eprintln!("clipboard <- host: {what} (seq {})", p.seq);
    } else {
        eprintln!("clipboard <- host: {what} (seq {}) — some formats failed to set", p.seq);
    }
}

/// Copy `bytes` into a movable HGLOBAL and hand it to the clipboard (which then owns it).
unsafe fn set_global(fmt: u32, bytes: &[u8]) -> bool {
    let Ok(hg) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else { return false };
    let p = GlobalLock(hg) as *mut u8;
    if p.is_null() {
        let _ = GlobalFree(Some(hg));
        return false;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
    let _ = GlobalUnlock(hg);
    if SetClipboardData(fmt, Some(HANDLE(hg.0))).is_err() {
        let _ = GlobalFree(Some(hg));
        return false;
    }
    true
}

fn worker(rx: mpsc::Receiver<Job>) {
    while let Ok(first) = rx.recv() {
        // Coalesce bursts: only the newest outgoing and newest incoming clipboard matter.
        let mut out = None;
        let mut inc = None;
        for job in std::iter::once(first).chain(std::iter::from_fn(|| rx.recv_timeout(Duration::from_millis(1)).ok())) {
            match job {
                j @ Job::Outgoing { .. } => out = Some(j),
                Job::Incoming(d) => inc = Some(d),
            }
        }
        let Some(c) = CLIP.get() else { return };
        if let Some(Job::Outgoing { clip, seq, max_bytes, generation }) = out {
            match clip.into_data(seq, max_bytes) {
                Ok(data) => {
                    let sender = c.peer.lock().unwrap().as_ref().filter(|p| p.generation == generation).map(|p| p.sender.clone());
                    if let Some(s) = sender {
                        eprintln!("clipboard -> host: {}", data.describe());
                        if let Err(e) = s.send(&ClientMsg::Clipboard(data)) {
                            eprintln!("clipboard: send failed: {e}");
                        }
                    }
                }
                Err(e) => eprintln!("clipboard: {e}"),
            }
        }
        if let Some(d) = inc {
            match prepare_incoming(&d) {
                Ok(p) => {
                    if c.peer.lock().unwrap().is_none() {
                        continue;
                    }
                    *c.pending.lock().unwrap() = Some(p);
                    let hwnd = c.hwnd.load(Ordering::Relaxed);
                    unsafe {
                        let _ = PostMessageW(Some(HWND(hwnd as *mut _)), WM_APP_CLIPBOARD, WPARAM(0), LPARAM(0));
                    }
                }
                Err(e) => eprintln!("clipboard: {e} (seq {})", d.seq),
            }
        }
    }
}

// ------------------------------------------------------------------ headless self-test

static TEST_UPDATES: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn test_wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_CLIPBOARDUPDATE {
        TEST_UPDATES.fetch_add(1, Ordering::Relaxed);
    }
    DefWindowProcW(hwnd, msg, wp, lp)
}

fn pump(ms: u64) {
    let end = std::time::Instant::now() + Duration::from_millis(ms);
    unsafe {
        let mut msg = MSG::default();
        while std::time::Instant::now() < end {
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// Write `items` to the clipboard as another app would (owner = `hwnd`).
unsafe fn external_write(hwnd: HWND, items: &[(u32, Vec<u8>)]) -> Result<(), String> {
    for _ in 0..MAX_TRIES {
        if OpenClipboard(Some(hwnd)).is_ok() {
            let _ = EmptyClipboard();
            let ok = items.iter().all(|(f, b)| set_global(*f, b));
            let _ = CloseClipboard();
            return if ok { Ok(()) } else { Err("SetClipboardData failed".into()) };
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    Err("OpenClipboard failed".into())
}

unsafe fn read_back(hwnd: HWND, fmt: u32) -> Result<(Option<LocalClip>, Option<Vec<u8>>), String> {
    let c = CLIP.get().ok_or("not initialized")?;
    OpenClipboard(Some(hwnd)).map_err(|e| format!("OpenClipboard: {e}"))?;
    let clip = read_open_clipboard(c, CLIP_CAPS_TEXT | CLIP_CAPS_PNG, false).ok().flatten();
    let raw = read_global(fmt);
    let _ = CloseClipboard();
    Ok((clip, raw))
}

/// `glide-client --clipboard-selftest`: exercises the real Win32 clipboard path (apply, read back,
/// echo suppression, external changes) on hidden windows. Run it over SSH: session 0 has its own
/// clipboard, so the interactive user's clipboard is untouched. Prints one line per check.
pub fn selftest() -> Result<(), String> {
    use crate::clipboard::{dib_to_rgba, png_to_rgba, rgba_to_dib, rgba_to_png, Rgba};
    let mut failures = 0;
    let mut check = |ok: bool, what: &str| {
        println!("  {} {what}", if ok { "ok  " } else { "FAIL" });
        if !ok {
            failures += 1;
        }
    };
    unsafe {
        let hinst = windows::Win32::System::LibraryLoader::GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class = w!("GlideClipboardTest");
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(test_wndproc),
            hInstance: HINSTANCE(hinst.0),
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassExW(&wc);
        let mk = || {
            CreateWindowExW(WINDOW_EX_STYLE(0), class, w!("t"), WS_OVERLAPPED, 0, 0, 10, 10, None, None, Some(HINSTANCE(hinst.0)), None)
                .map_err(|e| format!("CreateWindowExW: {e}"))
        };
        let hwnd = mk()?;
        let other = mk()?; // "another app"
        init(hwnd);
        let c = CLIP.get().ok_or("init failed")?;
        check(c.png_format != 0, "registered \"PNG\" clipboard format");
        pump(100);

        // 1. Text from the host: CRLF on the clipboard, LF when read back, own write not echoed.
        let before = TEST_UPDATES.load(Ordering::Relaxed);
        let sent = ClipboardData { seq: 1, text: Some("line1\nline2 ✓ 🎉".into()), png: None };
        *c.pending.lock().unwrap() = Some(prepare_incoming(&sent)?);
        apply_pending(hwnd);
        pump(150);
        check(TEST_UPDATES.load(Ordering::Relaxed) > before, "WM_CLIPBOARDUPDATE delivered for our write");
        let marker = GetClipboardSequenceNumber() as u64;
        check(!UI.with(|u| u.borrow_mut().guard.changed(marker)), "own write suppressed by sequence number");
        check(GetClipboardOwner().ok().map(|o| o.0) == Some(hwnd.0), "own write: clipboard owner is the viewer window");
        let (clip, raw) = read_back(hwnd, CF_UNICODETEXT)?;
        let raw16: Vec<u16> = raw.unwrap_or_default().chunks_exact(2).map(|b| u16::from_le_bytes([b[0], b[1]])).collect();
        let end = raw16.iter().position(|&u| u == 0).unwrap_or(raw16.len());
        check(String::from_utf16_lossy(&raw16[..end]) == "line1\r\nline2 ✓ 🎉", "CF_UNICODETEXT has CRLF");
        let back = clip.clone();
        check(back == Some(LocalClip::Text("line1\nline2 ✓ 🎉".into())), "read back as LF text");
        check(!UI.with(|u| u.borrow_mut().guard.should_send(back.unwrap().hash(), marker)), "own content suppressed by hash");

        // 2. Image from the host: "PNG" (exact bytes) + CF_DIB.
        let mut px = Vec::new();
        for i in 0..12u8 {
            px.extend_from_slice(&[i * 20, 255 - i * 20, i, if i == 5 { 128 } else { 255 }]);
        }
        let img = Rgba { w: 4, h: 3, px };
        let png = rgba_to_png(&img)?;
        *c.pending.lock().unwrap() = Some(prepare_incoming(&ClipboardData { seq: 2, text: None, png: Some(png.clone()) })?);
        apply_pending(hwnd);
        pump(100);
        let marker = GetClipboardSequenceNumber() as u64;
        check(!UI.with(|u| u.borrow_mut().guard.changed(marker)), "own image write suppressed");
        let (clip, dib) = read_back(hwnd, CF_DIB)?;
        check(clip == Some(LocalClip::Png(png.clone())), "image read back as the exact PNG bytes");
        let d = dib.map(|d| dib_to_rgba(&d));
        check(matches!(&d, Some(Ok(r)) if r.w == 4 && r.h == 3 && r.px[..4] == img.px[..4]), "CF_DIB set and decodable");

        // 3. Another app copies text: detected, read, sent.
        let ext: Vec<u8> = "ext\r\ntext\0".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        external_write(other, &[(CF_UNICODETEXT, ext)])?;
        pump(100);
        let marker = GetClipboardSequenceNumber() as u64;
        check(UI.with(|u| u.borrow_mut().guard.changed(marker)), "external change detected");
        check(GetClipboardOwner().ok().map(|o| o.0) != Some(hwnd.0), "external change: owner is not the viewer");
        let (clip, _) = read_back(hwnd, CF_UNICODETEXT)?;
        check(clip == Some(LocalClip::Text("ext\ntext".into())), "external CRLF text read as LF");
        check(UI.with(|u| u.borrow_mut().guard.should_send(clip.unwrap().hash(), marker)), "external text would be sent");
        // The host echoing that text back must not rewrite the (unchanged) clipboard.
        let echo = ClipboardData { seq: 3, text: Some("ext\ntext".into()), png: None };
        *c.pending.lock().unwrap() = Some(prepare_incoming(&echo)?);
        apply_pending(hwnd);
        pump(50);
        check(GetClipboardSequenceNumber() as u64 == marker, "echo of just-sent content not re-applied");

        // 4. Another app copies a DIB only (e.g. Paint): DIB -> PNG.
        external_write(other, &[(CF_DIB, rgba_to_dib(&Rgba { w: 2, h: 2, px: vec![255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 9, 9, 9, 255] }))])?;
        pump(100);
        let (clip, _) = read_back(hwnd, CF_DIB)?;
        let ok = match clip {
            Some(dib @ LocalClip::Dib(_)) => match dib.into_data(3, CLIPBOARD_MAX_BYTES) {
                Ok(ClipboardData { png: Some(p), .. }) => png_to_rgba(&p).map(|r| r.px[..8] == [255, 0, 0, 255, 0, 255, 0, 255]).unwrap_or(false),
                _ => false,
            },
            _ => false,
        };
        check(ok, "external DIB read and converted to PNG");

        // 5. Text wins over an image when both are present (Excel-style).
        let t: Vec<u8> = "cells\0".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        external_write(other, &[(CF_UNICODETEXT, t), (CF_DIB, rgba_to_dib(&img))])?;
        pump(50);
        let (clip, _) = read_back(hwnd, CF_UNICODETEXT)?;
        check(clip == Some(LocalClip::Text("cells".into())), "text preferred over image");

        // 6. Privacy markers (password managers): not sent unless --clipboard-sync-secrets.
        let fmt = |n: &str| {
            let wide: Vec<u16> = n.encode_utf16().chain(std::iter::once(0)).collect();
            RegisterClipboardFormatW(windows::core::PCWSTR(wide.as_ptr()))
        };
        let secret: Vec<u8> = "hunter2\0".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        let cases: [(&str, Vec<u8>, bool); 5] = [
            ("ExcludeClipboardContentFromMonitorProcessing", vec![], true),
            ("Clipboard Viewer Ignore", vec![], true),
            ("CanIncludeInClipboardHistory", 0u32.to_le_bytes().to_vec(), true),
            ("CanUploadToCloudClipboard", 0u32.to_le_bytes().to_vec(), true),
            ("CanIncludeInClipboardHistory", 1u32.to_le_bytes().to_vec(), false),
        ];
        for (name, value, private) in cases {
            external_write(other, &[(CF_UNICODETEXT, secret.clone()), (fmt(name), value)])?;
            OpenClipboard(Some(hwnd)).map_err(|e| format!("OpenClipboard: {e}"))?;
            let respected = read_open_clipboard(c, CLIP_CAPS_TEXT, false);
            let opted_in = read_open_clipboard(c, CLIP_CAPS_TEXT, true);
            let _ = CloseClipboard();
            let ok = if private {
                respected.as_ref().is_err_and(|e| e.contains(name) && !e.contains("hunter2"))
            } else {
                respected == Ok(Some(LocalClip::Text("hunter2".into())))
            };
            check(ok, &format!("{name}{} -> {}", if private { "" } else { "=1" }, if private { "not sent" } else { "sent" }));
            check(opted_in == Ok(Some(LocalClip::Text("hunter2".into()))), &format!("{name}: sent with --clipboard-sync-secrets"));
        }

        shutdown(hwnd);
        let _ = DestroyWindow(other);
        let _ = DestroyWindow(hwnd);
    }
    if failures == 0 {
        println!("CLIPBOARD SELFTEST PASSED");
        Ok(())
    } else {
        Err(format!("{failures} clipboard check(s) failed"))
    }
}
