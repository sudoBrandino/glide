//! The viewer: Win32 window + message loop (input, cursor, fullscreen) on the UI thread,
//! a render thread that owns D3D11 / the MF decoders / the swap chain, and a session thread
//! that (re)connects or (re)listens, runs one connection at a time (with its own receive
//! thread from `net`) and survives disconnects. Frames go network → render thread over a
//! channel and are presented as soon as they decode.
//!
//! UX layer: local hotkeys (`hotkeys`), a stats HUD and toasts drawn by the renderer, persisted
//! preferences / per-monitor window placement (`config::Store`), the pairing dialog (`prompt`,
//! security v2: key pinning + a 6-digit code confirmed on both screens), and a tray icon (`tray`).

use super::clipboard;
use super::files;
use super::audio::Audio;
use super::cursor::{create_cursor, destroy_cursor, scale_image, CursorImage};
use super::d3d::Gpu;
use super::decoder::Decoder;
use super::prompt::PairText;
use super::render::{Readback, Renderer};
use super::scanout::ScanoutClock;
use super::{connbar as cbar, menu, placement, prompt, tray};
use crate::menu_model::{self, Cmd};
use crate::config::{self, Store};
use crate::displays::{self, DisplayState};
use crate::hid;
use crate::hotkeys::{self, Action};
use crate::blockcode;
use crate::hud;
use crate::identity::Identity;
use crate::latency::Tracker;
use crate::net::{Auth, ClockSync, ConnectError, Connection, NetEvent, PairPrompt, PairingUi, Sender};
use crate::peers;
use crate::protocol::{self, ClientMsg, HostMsg, Mode, VideoConfig, FRAME_FLAG_KEYFRAME, FRAME_FLAG_SHARP};
use crate::util::{letterbox, now_us, present_rect};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, AtomicU8, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

pub struct Options {
    pub ctrl_as_cmd: bool,
    pub mode: Mode,
    pub host_label: String,
    /// This PC decodes HEVC 4:4:4 (sharp/hybrid modes available).
    pub has444: bool,
    /// Persisted preferences (HUD, mode, window placement).
    pub store: Store,
    /// Play the host's audio (§3.2); false with --no-audio / config "audio": false.
    pub audio: bool,
    /// Start muted (config "audio_muted").
    pub audio_muted: bool,
    /// Start in latency test mode (--latency-test / GLIDE_LATENCY_TEST=1; Ctrl+Alt+Shift+L).
    pub latency_test: bool,
    /// Clipboard sync switch at startup (config "clipboard" / --no-clipboard); toggled at runtime
    /// from the menu. ClientHello advertises clipboard support only while it is on.
    pub clipboard: bool,
}

/// How the viewer reaches the host. The session thread retries forever.
pub enum Target {
    /// Reverse connect: listen on 0.0.0.0:port and accept the host's connection.
    Listen(u16),
    /// Dial `host[:port]`, retrying every 2 s.
    Connect(String),
}

pub struct Connector {
    pub target: Target,
    /// This viewer's static key (identity.dpapi).
    pub identity: Identity,
    /// Pin-store key of the target (`config::pin_target`).
    pub pin_target: String,
    pub hello: ClientMsg,
}

const WM_APP_CURSOR: u32 = WM_APP + 1;
const WM_APP_CLOSED: u32 = WM_APP + 2;
const WM_APP_CONNECTED: u32 = WM_APP + 4;
const WM_APP_DISCONNECTED: u32 = WM_APP + 5;
/// wParam = `hotkeys::Action as u8`.
const WM_APP_HOTKEY: u32 = WM_APP + 6;
/// lParam = Box<PairRequest> (session thread → UI thread: show the pairing dialog).
const WM_APP_PAIR: u32 = WM_APP + 7;
/// Tray icon callback (see `tray`).
pub(super) const WM_APP_TRAY: u32 = WM_APP + 8;
const TITLE_TIMER: usize = 1;
const EXIT_TIMER: usize = 2;
const VIEW_TIMER: usize = 3;
/// Debounced save of the window placement after moves/resizes.
const PLACEMENT_TIMER: usize = 4;
/// `GLIDE_TEST_ACTIONS` test hook: fires one queued action per tick.
const TEST_ACTION_TIMER: usize = 5;

enum RenderCmd {
    Frame { frame_id: u32, data: Vec<u8>, keyframe: bool, sharp: bool, rects: Option<Vec<protocol::Rect>> },
    Config(VideoConfig),
    SharpConfig(VideoConfig),
    /// Status overlay text (None = connected, no overlay). Some dims the canvas.
    Status(Option<String>),
    /// Stats HUD lines (None = hidden).
    Hud(Option<Vec<String>>),
    /// Brief hotkey feedback, fades out by itself.
    Toast(String),
    /// Connection-bar tab text (None = hidden).
    Bar(Option<String>),
    Resize(u32, u32),
    Redraw,
    Quit,
}

#[derive(Default)]
struct CursorState {
    shapes: HashMap<u32, CursorImage>,
    current: Option<u32>,
    visible: bool,
}

#[derive(Default)]
struct Stats {
    decoded: AtomicU64,
    presented: AtomicU64,
    bytes: AtomicU64,
    decode_us_total: AtomicU64,
    decode_errors: AtomicU64,
    sharp: AtomicU64,
    rect_frames: AtomicU64,
    /// 1 if the most recent canvas update came from the sharp (4:4:4) layer.
    showing_sharp: AtomicU64,
}

struct Shared {
    host_name: Mutex<String>,
    /// Current stream mode (`Mode as u8`); changed by Ctrl+Alt+Shift+M, used for (re)connects.
    mode: AtomicU8,
    has444: bool,
    /// Ask the host to pair again even though a key is pinned (it said it doesn't know us).
    repair: AtomicBool,
    /// Ctrl+Alt+Shift+D: the current connection was dropped on purpose; reconnect immediately.
    reconnect: AtomicBool,
    /// Tray "Disconnect": stay disconnected (and stop listening) until "Connect".
    paused: AtomicBool,
    /// Interrupts a pending accept (quit or pause).
    abort_accept: AtomicBool,
    /// Listen (reverse-connect) mode: inbound peers are untrusted until authenticated.
    listening: bool,
    /// Set by the session thread when trust-on-first-use pinned the host's IP (shown on connect).
    just_pinned: Mutex<Option<String>>,
    /// Set by the session thread when this connection paired (toast on connect).
    just_paired: Mutex<Option<String>>,
    /// Pin-store key of the target (`config::pin_target`).
    pin_target: String,
    /// Zero-sized until the first connection.
    config: Mutex<VideoConfig>,
    /// Current connection's writer; None while disconnected.
    sender: Mutex<Option<Sender>>,
    clock: Mutex<Option<Arc<Mutex<ClockSync>>>>,
    /// Status text shown in the window while not connected.
    status: Mutex<Option<String>>,
    quit: AtomicBool,
    /// (w, h, max_fps) of the monitor the window is on (physical pixels). UI-thread owned.
    view: Mutex<(u16, u16, u8)>,
    /// Last view size the host was told (ClientHello or ViewSize).
    sent_view: Mutex<(u16, u16)>,
    /// GLIDE_VIEW override: report a fixed view size and never send ViewSize.
    view_override: Option<(u16, u16)>,
    decoder_desc: Mutex<String>,
    cursor: Mutex<CursorState>,
    stats: Stats,
    hwnd: AtomicIsize,
    /// Mac display preference/mode from the host (DisplayInfo, §3.3); None until received.
    display_info: Mutex<Option<menu_model::DisplayInfo>>,
    /// The Mac's displays (DisplayList, §3.5); None until received (old hosts never send it).
    displays: Mutex<Option<DisplayState>>,
    /// This connection already tried to re-select the remembered display.
    display_restore_done: AtomicBool,
    /// The display id re-selected from memory, until the host answers (toast "remembered").
    display_restoring: Mutex<Option<u32>>,
    /// Audio output (None with --no-audio).
    audio: Option<Audio>,
    /// Per-frame latency breakdown (docs/LATENCY.md). Written by the receive and render
    /// threads, summarized by the UI thread.
    latency: Mutex<Tracker>,
    /// Latency test mode: read the host's block-code test pattern back from the canvas.
    latency_test: AtomicBool,
    /// Present path facts for latency reports (set by the render thread).
    present_info: Mutex<String>,
    /// Clock-sync facts for latency reports (kept after a disconnect).
    clock_info: Mutex<String>,
}

/// Process-wide UI context (the low-level keyboard hook has no user pointer).
struct UiCtx {
    ctrl_as_cmd: bool,
    render_tx: Mutex<mpsc::Sender<RenderCmd>>,
    shared: Arc<Shared>,
    store: Mutex<Store>,
}

static UI: OnceLock<UiCtx> = OnceLock::new();

/// One `GLIDE_TEST_ACTIONS` step: a hotkey action, `menu:<cmd>`, or `bar` (reveal the bar).
#[derive(Debug, Clone, Copy)]
enum TestStep {
    Action(Action),
    Menu(Cmd),
    Bar,
}

impl TestStep {
    fn parse(s: &str) -> Option<TestStep> {
        let s = s.trim();
        if s == "bar" {
            return Some(TestStep::Bar);
        }
        if let Some(c) = s.strip_prefix("menu:") {
            return Cmd::from_name(c).map(TestStep::Menu);
        }
        Action::from_name(s).map(TestStep::Action)
    }
}

/// UI-thread-only mutable state.
#[derive(Default)]
struct UiState {
    hook: Option<HHOOK>,
    fullscreen_saved: Option<(isize, WINDOWPLACEMENT)>,
    last_move: Option<(f32, f32)>,
    keys_down: HashSet<u16>,
    buttons_down: u8,
    swallow_up: HashSet<u16>,
    cursor_cache: HashMap<(u32, u32), HCURSOR>,
    stats_last: Option<hud::Counters>,
    focused: bool,
    last_title: String,
    /// Ctrl+Alt+Shift+K: keyboard released to Windows (no LL hook, nothing forwarded).
    kb_released: bool,
    hud_on: bool,
    last_hud: Vec<String>,
    /// Last normal (not maximized / fullscreen / minimized) outer window rect.
    normal_rect: Option<RECT>,
    test_actions: Vec<TestStep>,
    /// Mouse buttons whose down went to the connection bar (their ups aren't forwarded either).
    bar_buttons: u8,
    tray: Option<tray::Tray>,
    /// The last tray balloon was "files received": clicking it shows them in Explorer.
    balloon_shows_files: bool,
    last_latency_report: Option<Instant>,
    last_latency_log: Option<Instant>,
}

thread_local! {
    static STATE: RefCell<UiState> = RefCell::new(UiState::default());
}

fn ui() -> &'static UiCtx {
    UI.get().expect("UI context")
}

fn send(msg: ClientMsg) {
    let s = ui().shared.sender.lock().unwrap().clone();
    if let Some(s) = s {
        let _ = s.send(&msg);
    }
}

fn connected() -> bool {
    ui().shared.sender.lock().unwrap().is_some()
}

fn client_size(hwnd: HWND) -> (u32, u32) {
    let mut rc = RECT::default();
    unsafe {
        let _ = GetClientRect(hwnd, &mut rc);
    }
    ((rc.right - rc.left).max(0) as u32, (rc.bottom - rc.top).max(0) as u32)
}

fn video_rect(hwnd: HWND) -> (i32, i32, i32, i32) {
    let (cw, ch) = client_size(hwnd);
    let c = *ui().shared.config.lock().unwrap();
    present_rect(cw, ch, c.width as u32, c.height as u32)
}

/// Debounced (~300 ms) check of which monitor the window is on.
fn schedule_view_check(hwnd: HWND) {
    unsafe {
        SetTimer(Some(hwnd), VIEW_TIMER, 300, None);
    }
}

/// Update the view size from the window's monitor; tell the host if it changed.
fn check_view(hwnd: HWND) {
    let sh = &ui().shared;
    let Some(m) = (unsafe { super::monitor_info(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)) }) else { return };
    let (w, h) = sh.view_override.unwrap_or((m.w, m.h));
    *sh.view.lock().unwrap() = (w, h, m.fps);
    if sh.view_override.is_none() && connected() {
        let changed = {
            let mut sent = sh.sent_view.lock().unwrap();
            let c = *sent != (w, h);
            *sent = (w, h);
            c
        };
        if changed {
            eprintln!("view size -> {w}x{h} (monitor changed); sending ViewSize");
            send(ClientMsg::ViewSize { view_w: w, view_h: h });
        }
    }
    update_title(hwnd);
}

// ------------------------------------------------------------------ render thread

fn render_thread(hwnd_raw: isize, rx: mpsc::Receiver<RenderCmd>, shared: Arc<Shared>, init: (u32, u32)) {
    let hwnd = HWND(hwnd_raw as *mut _);
    let fail = |e: String| {
        eprintln!("fatal: {e}");
        *shared.status.lock().unwrap() = Some(e);
        unsafe {
            let _ = PostMessageW(Some(hwnd), WM_APP_CLOSED, WPARAM(0), LPARAM(0));
        }
    };
    let gpu = match Gpu::new() {
        Ok(g) => g,
        Err(e) => return fail(format!("D3D11 init failed: {e}")),
    };
    let tearing = std::env::var("GLIDE_TEARING").map(|v| v == "1").unwrap_or(false);
    let mut renderer = match Renderer::new(&gpu, hwnd, init.0, init.1, tearing) {
        Ok(r) => r,
        Err(e) => return fail(format!("renderer init failed: {e}")),
    };
    let mut cfg = *shared.config.lock().unwrap(); // zero-sized until the first VideoConfig
    let mut sharp_cfg: Option<VideoConfig> = None;
    let mut dim = 1.0f32;
    let dpi_px = |pt: i32| unsafe { (GetDpiForWindow(hwnd).max(96) as i32 * pt) / 96 };
    let overlay_px = || dpi_px(22);
    // Toast: fully visible for TOAST_HOLD, then fades out over TOAST_FADE.
    const TOAST_HOLD: Duration = Duration::from_millis(1400);
    const TOAST_FADE: Duration = Duration::from_millis(350);
    let mut toast_since: Option<Instant> = None;
    let mut hud_lines: Option<Vec<String>> = None;
    // Base layer decoder (continuous 4:2:0 stream) and sharp-layer decoder (standalone 4:4:4 IDRs).
    let mut sdec: Option<Decoder> = None;
    let mut need_key = true;
    let describe = |d: &Option<Decoder>, s: &Option<Decoder>| {
        let one = |d: &Decoder| format!("{} {}", if d.d3d { "hw" } else { "sw" }, d.out_fmt.map(|f| f.name()).unwrap_or("?"));
        let mut t = d.as_ref().map(one).unwrap_or_else(|| "no decoder".into());
        if let Some(s) = s {
            t.push_str(&format!(" + {}", s.out_fmt.map(|f| f.name()).unwrap_or("?")));
        }
        t
    };
    let new_decoder = |c: &VideoConfig| -> Option<Decoder> {
        match Decoder::new(&gpu, c) {
            Ok(d) => Some(d),
            Err(e) => {
                eprintln!("decoder create failed ({} {}): {e}", c.codec.name(), c.chroma_name());
                *shared.decoder_desc.lock().unwrap() = format!("decoder error: {e}");
                None
            }
        }
    };
    let reset_canvas = |renderer: &mut Renderer, c: &VideoConfig| {
        if let Err(e) = renderer.reset_canvas(c.width as u32, c.height as u32) {
            eprintln!("canvas create failed: {e}");
        }
    };
    let mut dec: Option<Decoder> = None;
    if let Some(s) = shared.status.lock().unwrap().clone() {
        let _ = renderer.set_overlay(Some(&s), overlay_px());
    }
    // Latency instrumentation: present -> scan-out from DXGI frame statistics, and (test mode)
    // canvas readback of the host's block-code pattern.
    let mut scan = ScanoutClock::new();
    let mut lt = LatencyTest::default();
    let mut last_info = Instant::now() - Duration::from_secs(10);

    let dump = std::env::var("GLIDE_DUMP_FRAME").ok();
    let finish = |renderer: &Renderer| {
        if let Some(p) = &dump {
            match renderer.dump_bmp(p) {
                Ok(()) => eprintln!("dumped last rendered frame to {p} (offscreen={})", renderer.is_offscreen()),
                Err(e) => eprintln!("dump failed: {e}"),
            }
        }
    };
    loop {
        // While presents await their scan-out time (or readbacks are in flight), poll every 2 ms;
        // while a toast is fading, wake up ~30x/s to animate it; otherwise block.
        let awaiting = !renderer.is_offscreen() && shared.latency.lock().unwrap().awaiting_scanout(now_us());
        let wait = if awaiting || !lt.pending.is_empty() {
            Some(Duration::from_millis(2))
        } else if toast_since.is_some() {
            Some(Duration::from_millis(33))
        } else {
            None
        };
        let first = if let Some(wait) = wait {
            match rx.recv_timeout(wait) {
                Ok(c) => Some(c),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        } else {
            match rx.recv() {
                Ok(c) => Some(c),
                Err(_) => break,
            }
        };
        let mut cmds: Vec<RenderCmd> = first.into_iter().collect();
        while let Ok(c) = rx.try_recv() {
            cmds.push(c);
        }
        let mut redraw = false;
        let mut new_frame = false;
        let mut resize = None;
        // Frames whose canvas updates the next present shows (latency tracking).
        let mut shown: Vec<u32> = Vec::new();
        for c in cmds {
            match c {
                RenderCmd::Quit => return finish(&renderer),
                RenderCmd::Config(c) => {
                    // New base configuration: reset base decoder and canvas.
                    cfg = c;
                    drop(dec.take()); // release the old MFT before creating a new one
                    dec = new_decoder(&cfg);
                    reset_canvas(&mut renderer, &cfg);
                    need_key = true;
                    redraw = true;
                }
                RenderCmd::Status(text) => {
                    if let Err(e) = renderer.set_overlay(text.as_deref(), overlay_px()) {
                        eprintln!("overlay failed: {e}");
                    }
                    dim = if text.is_some() { 0.35 } else { 1.0 };
                    redraw = true;
                }
                RenderCmd::Hud(lines) => {
                    // Re-rasterize only when the text changed (≤ 2x/s).
                    if lines != hud_lines {
                        if let Err(e) = renderer.set_hud(lines.as_deref(), dpi_px(15)) {
                            eprintln!("hud failed: {e}");
                        }
                        hud_lines = lines;
                        redraw = true;
                    }
                }
                RenderCmd::Bar(text) => {
                    match renderer.set_bar(text.as_deref(), dpi_px(13)) {
                        Ok(Some((w, h))) => cbar::set_size(w, h),
                        Ok(None) => {}
                        Err(e) => eprintln!("connection bar failed: {e}"),
                    }
                    redraw = true;
                }
                RenderCmd::Toast(text) => {
                    if let Err(e) = renderer.set_toast(Some(&text), dpi_px(19)) {
                        eprintln!("toast failed: {e}");
                    }
                    toast_since = Some(Instant::now());
                    redraw = true;
                }
                RenderCmd::SharpConfig(c) => {
                    sharp_cfg = Some(c);
                    drop(sdec.take());
                    sdec = new_decoder(&c);
                }
                RenderCmd::Resize(w, h) => resize = Some((w, h)),
                RenderCmd::Redraw => redraw = true,
                RenderCmd::Frame { frame_id, data, sharp: true, .. } => {
                    // Sharp layer: standalone IDR → whole frame into the canvas. Independent of
                    // the base decoder's reference chain.
                    if sdec.is_none() {
                        let c = *sharp_cfg.get_or_insert(VideoConfig { codec: protocol::Codec::Hevc, chroma: 1, ..cfg });
                        sdec = new_decoder(&c);
                    }
                    let Some(d) = sdec.as_mut() else { continue };
                    let t0 = now_us();
                    match d.decode(&data, true) {
                        Ok(n) => {
                            let t1 = now_us();
                            shared.stats.decode_us_total.fetch_add(t1 - t0, Ordering::Relaxed);
                            if n > 0 {
                                if let Some(f) = d.frame.as_ref() {
                                    renderer.apply(f, None);
                                }
                                let mut l = shared.latency.lock().unwrap();
                                l.on_decode(frame_id, t0, t1);
                                l.on_canvas(frame_id, now_us());
                                drop(l);
                                shown.push(frame_id);
                                shared.stats.decoded.fetch_add(n as u64, Ordering::Relaxed);
                                shared.stats.sharp.fetch_add(1, Ordering::Relaxed);
                                shared.stats.showing_sharp.store(1, Ordering::Relaxed);
                                new_frame = true;
                            }
                        }
                        Err(e) => {
                            shared.stats.decode_errors.fetch_add(1, Ordering::Relaxed);
                            eprintln!("sharp-layer decode error: {e}; recreating sharp decoder");
                            sdec = None;
                            if let Some(c) = sharp_cfg {
                                sdec = new_decoder(&c);
                            }
                        }
                    }
                }
                RenderCmd::Frame { frame_id, data, keyframe, sharp: false, rects } => {
                    if need_key && !keyframe {
                        continue;
                    }
                    let Some(d) = dec.as_mut() else { continue };
                    need_key = false;
                    let t0 = now_us();
                    match d.decode(&data, keyframe) {
                        Ok(n) => {
                            let t1 = now_us();
                            shared.stats.decode_us_total.fetch_add(t1 - t0, Ordering::Relaxed);
                            if n > 0 {
                                if let Some(f) = d.frame.as_ref() {
                                    // Rects apply only to non-keyframes (§3.1).
                                    match (&rects, keyframe) {
                                        (Some(rs), false) => {
                                            let clamped: Vec<(u32, u32, u32, u32)> =
                                                rs.iter().filter_map(|r| r.clamped(f.w, f.h)).collect();
                                            renderer.apply(f, Some(&clamped));
                                            shared.stats.rect_frames.fetch_add(1, Ordering::Relaxed);
                                        }
                                        _ => {
                                            renderer.apply(f, None);
                                            // A full base update replaces any sharp pixels.
                                            shared.stats.showing_sharp.store(0, Ordering::Relaxed);
                                        }
                                    }
                                }
                                shared.stats.decoded.fetch_add(n as u64, Ordering::Relaxed);
                                new_frame = true;
                                let mut l = shared.latency.lock().unwrap();
                                l.on_decode(frame_id, t0, t1);
                                l.on_canvas(frame_id, now_us());
                                drop(l);
                                shown.push(frame_id);
                            }
                        }
                        Err(e) => {
                            shared.stats.decode_errors.fetch_add(1, Ordering::Relaxed);
                            eprintln!("decode error: {e}; requesting keyframe");
                            if let Some(s) = shared.sender.lock().unwrap().clone() {
                                let _ = s.send(&ClientMsg::RequestKeyframe);
                            }
                            drop(dec.take());
                            dec = new_decoder(&cfg);
                            need_key = true;
                        }
                    }
                }
            }
        }
        if let Some(t0) = toast_since {
            let age = t0.elapsed();
            if age >= TOAST_HOLD + TOAST_FADE {
                let _ = renderer.set_toast(None, 0);
                toast_since = None;
                redraw = true;
            } else if age > TOAST_HOLD {
                renderer.set_toast_opacity(1.0 - (age - TOAST_HOLD).as_secs_f32() / TOAST_FADE.as_secs_f32());
                redraw = true;
            }
        }
        if let Some((w, h)) = resize {
            if let Err(e) = renderer.resize(w, h) {
                eprintln!("resize failed: {e}");
            }
            redraw = true;
        }
        if new_frame || redraw {
            let want = describe(&dec, &sdec);
            let mut desc = shared.decoder_desc.lock().unwrap();
            if !desc.starts_with("decoder error") && *desc != want {
                *desc = want;
            }
        }
        // Present the canvas (also on resize/expose, without needing a new frame).
        if (new_frame || redraw) && !unsafe { IsIconic(hwnd) }.as_bool() {
            renderer.wait_ready(100);
            let (bw, bh) = renderer.size;
            let (vw, vh) = renderer.canvas_size().unwrap_or((cfg.width as u32, cfg.height as u32));
            // 1:1 when the video matches the window/monitor (no resample blur), else filtered fit.
            let rect = present_rect(bw, bh, vw, vh);
            match renderer.present(rect, dim) {
                Err(e) => eprintln!("present failed: {e}"),
                Ok(t_call) => {
                    if new_frame {
                        shared.stats.presented.fetch_add(1, Ordering::Relaxed);
                    }
                    let present_id = renderer.last_present_count().map(|c| c as u64);
                    if !shown.is_empty() {
                        shared.latency.lock().unwrap().on_present(&shown, t_call, present_id);
                        if shared.latency_test.load(Ordering::Relaxed) {
                            lt.after_present(&renderer, t_call, present_id, shown.last().copied());
                        }
                    }
                }
            }
        }
        // Scan-out times of earlier presents.
        if !renderer.is_offscreen() {
            if let Some(st) = renderer.frame_stats() {
                let hz = shared.view.lock().unwrap().2.max(1) as f64;
                if let Some((pc, t)) = scan.poll(st, hz) {
                    shared.latency.lock().unwrap().on_scanout(pc, t);
                }
            }
        }
        if !lt.pending.is_empty() {
            lt.poll(&renderer, &shared);
        }
        if last_info.elapsed() > Duration::from_secs(2) {
            last_info = Instant::now();
            *shared.present_info.lock().unwrap() = format!(
                "{{\"offscreen\":{},\"tearing\":{},\"refresh_hz_measured\":{},\"monitor_hz\":{}}}",
                renderer.is_offscreen(),
                renderer.tearing(),
                crate::util::json_opt(scan.refresh_hz()),
                shared.view.lock().unwrap().2
            );
        }
    }
}

/// Latency test mode (render thread): copies the block-code region of the canvas after each
/// present that showed new frames, maps it a few ms later without stalling, decodes the host
/// clock in it and records the first present that showed each value (docs/LATENCY.md).
#[derive(Default)]
struct LatencyTest {
    loc: Option<blockcode::Loc>,
    misses: u32,
    last_locate: Option<Instant>,
    pending: std::collections::VecDeque<(Readback, RbMeta)>,
    spare: Option<Readback>,
    last_value: Option<u32>,
}

struct RbMeta {
    full: bool,
    present_t: u64,
    present_id: Option<u64>,
    last_frame: Option<u32>,
}

impl LatencyTest {
    fn after_present(&mut self, r: &Renderer, present_t: u64, present_id: Option<u64>, last_frame: Option<u32>) {
        if self.pending.len() >= 8 {
            return;
        }
        let meta = |full| RbMeta { full, present_t, present_id, last_frame };
        if let Some(loc) = self.loc {
            let cell = loc.cell.max(1.0);
            let x = (loc.x0 - 2.0 * cell).max(0.0) as u32;
            let w = (60.0 * cell) as u32;
            let y = loc.y.saturating_sub(1) as u32;
            if let Some(rb) = r.read_canvas(x, y, w, 3, self.spare.take()) {
                self.pending.push_back((rb, meta(false)));
            }
        } else if self.last_locate.is_none_or(|t| t.elapsed() > Duration::from_millis(500)) && !self.pending.iter().any(|p| p.1.full) {
            // Full-canvas search (≤ 2x/s until found).
            self.last_locate = Some(Instant::now());
            if let Some((cw, ch)) = r.canvas_size() {
                if let Some(rb) = r.read_canvas(0, 0, cw, ch, None) {
                    self.pending.push_back((rb, meta(true)));
                }
            }
        }
    }

    fn poll(&mut self, r: &Renderer, shared: &Shared) {
        while let Some((rb, _)) = self.pending.front() {
            let Some(luma) = r.try_read_luma(rb) else { return }; // GPU not done: keep order
            let (rb, m) = self.pending.pop_front().unwrap();
            let (w, h) = (rb.w as usize, rb.h as usize);
            let code = if m.full {
                let found = blockcode::locate(&luma, w, h, w);
                if let Some((loc, _)) = found {
                    eprintln!("latency test: pattern found at x={:.0} y={} cell {:.1}px", loc.x0, loc.y, loc.cell);
                    self.loc = Some(loc);
                    self.misses = 0;
                }
                found.map(|f| f.1)
            } else {
                let loc = self.loc;
                let c = loc.and_then(|loc| [1usize, 0, 2].iter().filter(|&&y| y < h).find_map(|&y| blockcode::read_at(&luma[y * w..(y + 1) * w], &loc, rb.x as usize)));
                self.spare = Some(rb);
                c
            };
            match code {
                Some(c) => {
                    self.misses = 0;
                    if self.last_value != Some(c.value) {
                        self.last_value = Some(c.value);
                        let clock = shared.clock.lock().unwrap().clone();
                        let host_now = clock.and_then(|c| c.lock().unwrap().client_to_host_us(m.present_t));
                        if let Some(hn) = host_now {
                            let host_us = blockcode::unwrap32(c.value, hn.max(0) as u64);
                            shared.latency.lock().unwrap().on_ground_truth(host_us, c.kind, m.present_t, m.present_id, m.last_frame);
                        }
                    }
                }
                None if !m.full => {
                    self.misses += 1;
                    if self.misses > 30 {
                        eprintln!("latency test: pattern lost; searching again");
                        self.loc = None;
                        self.misses = 0;
                    }
                }
                None => {}
            }
        }
    }
}

// ------------------------------------------------------------------ input

fn release_all(hwnd: HWND) {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.keys_down.clear();
        s.swallow_up.clear();
        s.buttons_down = 0;
    });
    unsafe {
        let _ = ReleaseCapture();
    }
    let _ = hwnd;
    send(ClientMsg::ReleaseAll);
}

/// Translate one key event (from the LL hook or WM_KEY*). Returns true if consumed.
fn handle_key(hwnd: HWND, vk: u32, scan: u32, extended: bool, down: bool) -> bool {
    // AltGr produces a fake LCtrl with scancode 0x21D: drop it (RAlt is sent on its own).
    if scan & 0x200 != 0 {
        return true;
    }
    let sc = (scan & 0xFF) as u16 | if extended { hid::EXT } else { 0 };
    let usage = match VIRTUAL_KEY(vk as u16) {
        VK_PAUSE => Some(hid::HID_PAUSE),
        VK_NUMLOCK => Some(hid::HID_NUMLOCK),
        VK_SNAPSHOT => Some(hid::HID_PRINTSCREEN),
        VK_RSHIFT => Some(hid::HID_RSHIFT),
        VK_LSHIFT => Some(hid::HID_LSHIFT),
        _ => hid::scancode_to_hid(sc).or_else(|| match vk {
            0x41..=0x5A => Some(0x04 + (vk - 0x41) as u16), // A-Z without a scancode
            0x31..=0x39 => Some(0x1E + (vk - 0x31) as u16),
            0x30 => Some(0x27),
            _ => None,
        }),
    };
    let Some(usage) = usage else { return true };

    // Local hotkeys (F11, Alt+Enter, Ctrl+Alt+Shift+letter): handled here, never forwarded.
    // Matched on physical keys; the action runs later on the UI thread (we may be in the LL hook).
    let mods = STATE.with(|s| hotkeys::Mods::from_held(s.borrow().keys_down.iter().copied()));
    if down {
        if let Some(a) = hotkeys::match_hotkey(mods, usage) {
            STATE.with(|s| s.borrow_mut().swallow_up.insert(usage));
            unsafe {
                let _ = PostMessageW(Some(hwnd), WM_APP_HOTKEY, WPARAM(a as usize), LPARAM(0));
            }
            return true;
        }
    }
    if !down && STATE.with(|s| s.borrow_mut().swallow_up.remove(&usage)) {
        return true;
    }

    // Track physical (pre-remap) state for the Alt check above.
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        if down {
            s.keys_down.insert(usage);
        } else {
            s.keys_down.remove(&usage);
        }
    });
    // While disconnected or with the keyboard released, keys behave normally on this PC.
    if !connected() || STATE.with(|s| s.borrow().kb_released) {
        return false;
    }
    let out = if ui().ctrl_as_cmd { hid::remap_ctrl_as_cmd(usage) } else { usage };
    // Typematic repeats are forwarded as additional down events.
    send(ClientMsg::Key { hid_usage: out, down });
    true
}

/// A Glide menu (context or system menu) is open: the LL hook lets keys through to it.
static MENU_OPEN: AtomicBool = AtomicBool::new(false);

unsafe extern "system" fn ll_keyboard(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        if let Some(ctx) = UI.get() {
            let ours = ctx.shared.hwnd.load(Ordering::Relaxed);
            let fg = GetForegroundWindow();
            // While a Glide menu is open, keys navigate the menu (not the Mac).
            if fg.0 as isize == ours && ours != 0 && !MENU_OPEN.load(Ordering::Relaxed) {
                let kb = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
                let msg = wparam.0 as u32;
                let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                let ext = kb.flags.0 & LLKHF_EXTENDED.0 != 0;
                if handle_key(HWND(ours as *mut _), kb.vkCode, kb.scanCode, ext, down) {
                    return LRESULT(1);
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

fn set_focus_state(hwnd: HWND, active: bool) {
    let was = STATE.with(|s| s.borrow().focused);
    if active == was {
        return;
    }
    STATE.with(|s| s.borrow_mut().focused = active);
    if active {
        if !STATE.with(|s| s.borrow().kb_released) {
            install_hook();
        }
    } else {
        remove_hook();
        release_all(hwnd);
    }
}

fn install_hook() {
    if STATE.with(|s| s.borrow().hook.is_some()) {
        return;
    }
    let hook = unsafe {
        SetWindowsHookExW(WH_KEYBOARD_LL, Some(ll_keyboard), GetModuleHandleW(None).ok().map(|m| HINSTANCE(m.0)), 0).ok()
    };
    STATE.with(|s| s.borrow_mut().hook = hook);
}

fn remove_hook() {
    if let Some(h) = STATE.with(|s| s.borrow_mut().hook.take()) {
        unsafe {
            let _ = UnhookWindowsHookEx(h);
        }
    }
}

fn mouse_pos(hwnd: HWND, lparam: LPARAM) -> (f32, f32) {
    let x = (lparam.0 & 0xFFFF) as i16 as f32;
    let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as f32;
    let (rx, ry, rw, rh) = video_rect(hwnd);
    if rw <= 0 || rh <= 0 {
        return (0.5, 0.5);
    }
    (((x + 0.5 - rx as f32) / rw as f32).clamp(0.0, 1.0), ((y + 0.5 - ry as f32) / rh as f32).clamp(0.0, 1.0))
}

fn lparam_xy(lparam: LPARAM) -> (i32, i32) {
    ((lparam.0 & 0xFFFF) as i16 as i32, ((lparam.0 >> 16) & 0xFFFF) as i16 as i32)
}

/// WM_MOUSEMOVE: the connection bar sees it first; over the tab nothing goes to the Mac.
fn mouse_move(hwnd: HWND, lparam: LPARAM) {
    let (x, y) = lparam_xy(lparam);
    let held = STATE.with(|s| s.borrow().buttons_down != 0);
    if !cbar::on_mouse_move(hwnd, x, y, held) {
        send_move(hwnd, lparam);
    }
}

fn send_move(hwnd: HWND, lparam: LPARAM) {
    let p = mouse_pos(hwnd, lparam);
    let changed = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let c = s.last_move != Some(p);
        s.last_move = Some(p);
        c
    });
    if changed {
        send(ClientMsg::MouseMove { x: p.0, y: p.1 });
    }
}

fn button(hwnd: HWND, lparam: LPARAM, b: u8, down: bool) {
    // Connection bar: a press on the tab is ours (left opens the menu); so is its release.
    let (x, y) = lparam_xy(lparam);
    let nothing_held = STATE.with(|s| s.borrow().buttons_down == 0);
    if down && nothing_held && cbar::hit(hwnd, x, y) {
        STATE.with(|s| s.borrow_mut().bar_buttons |= 1 << b);
        if b == protocol::MOUSE_LEFT {
            STATE.with(|s| s.borrow_mut().bar_buttons &= !(1 << b)); // the menu loop eats the up
            open_menu(hwnd, menu::Anchor::Below(cbar::menu_anchor(hwnd)));
        }
        return;
    }
    if !down && STATE.with(|s| std::mem::take(&mut s.borrow_mut().bar_buttons) & (1 << b) != 0) {
        return;
    }
    send_move(hwnd, lparam);
    // Update state first; never hold the RefCell borrow across Win32 calls that may re-enter wndproc.
    let any_down = STATE.with(|s| {
        let mut s = s.borrow_mut();
        if down {
            s.buttons_down |= 1 << b;
        } else {
            s.buttons_down &= !(1 << b);
        }
        s.buttons_down != 0
    });
    unsafe {
        if down {
            SetCapture(hwnd);
        } else if !any_down {
            let _ = ReleaseCapture();
        }
    }
    send(ClientMsg::MouseButton { button: b, down });
}

// ------------------------------------------------------------------ cursor

fn current_cursor(hwnd: HWND) -> Option<HCURSOR> {
    let ctx = ui();
    if !connected() {
        return unsafe { LoadCursorW(None, IDC_ARROW).ok() };
    }
    let (id, img, visible) = {
        let c = ctx.shared.cursor.lock().unwrap();
        match c.current {
            Some(id) => (id, c.shapes.get(&id).cloned(), c.visible),
            None => return unsafe { LoadCursorW(None, IDC_ARROW).ok() },
        }
    };
    if !visible {
        return None;
    }
    let img = img?;
    let (_, _, rw, _) = video_rect(hwnd);
    let vw = ctx.shared.config.lock().unwrap().width.max(1) as f32;
    let scale = (rw as f32 / vw).clamp(0.25, 4.0);
    let key = (id, (scale * 1000.0) as u32);
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        if let Some(c) = s.cursor_cache.get(&key) {
            return Some(*c);
        }
        let c = create_cursor(&scale_image(&img, scale))?;
        if s.cursor_cache.len() > 64 {
            for (_, old) in s.cursor_cache.drain() {
                destroy_cursor(old);
            }
        }
        s.cursor_cache.insert(key, c);
        Some(c)
    })
}

fn apply_cursor_if_inside(hwnd: HWND) {
    unsafe {
        let mut pt = POINT::default();
        if GetCursorPos(&mut pt).is_err() {
            return;
        }
        if WindowFromPoint(pt) != hwnd {
            return;
        }
        let _ = ScreenToClient(hwnd, &mut pt);
        let (x, y, w, h) = video_rect(hwnd);
        if pt.x >= x && pt.x < x + w && pt.y >= y && pt.y < y + h {
            SetCursor(current_cursor(hwnd));
        }
    }
}

// ------------------------------------------------------------------ window

fn toggle_fullscreen(hwnd: HWND) {
    unsafe {
        let saved = STATE.with(|s| s.borrow_mut().fullscreen_saved.take());
        if let Some((style, wp)) = saved {
            SetWindowLongPtrW(hwnd, GWL_STYLE, style);
            let _ = SetWindowPlacement(hwnd, &wp);
            let _ = SetWindowPos(
                hwnd,
                None,
                0,
                0,
                0,
                0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
            );
        } else {
            let style = GetWindowLongPtrW(hwnd, GWL_STYLE);
            let mut wp = WINDOWPLACEMENT { length: std::mem::size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
            let _ = GetWindowPlacement(hwnd, &mut wp);
            // Never restore into a hidden/minimized state (the window may not be shown yet).
            if wp.showCmd != SW_SHOWMAXIMIZED.0 as u32 {
                wp.showCmd = SW_SHOWNORMAL.0 as u32;
            }
            let mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
            if GetMonitorInfoW(mon, &mut mi).as_bool() {
                // Mark fullscreen first: the WM_SIZE below must not be taken as the normal rect.
                STATE.with(|s| s.borrow_mut().fullscreen_saved = Some((style, wp)));
                SetWindowLongPtrW(hwnd, GWL_STYLE, style & !(WS_OVERLAPPEDWINDOW.0 as isize));
                let r = mi.rcMonitor;
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOP),
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top,
                    SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
                );
            }
        }
    }
}

fn is_fullscreen() -> bool {
    STATE.with(|s| s.borrow().fullscreen_saved.is_some())
}

fn current_mode() -> Mode {
    Mode::from_u8(ui().shared.mode.load(Ordering::Relaxed))
}

/// Sample the stats (every 500 ms) → window title + HUD.
fn update_title(hwnd: HWND) {
    let ctx = ui();
    let sh = &ctx.shared;
    let now = hud::Counters {
        t_us: now_us(),
        decoded: sh.stats.decoded.load(Ordering::Relaxed),
        presented: sh.stats.presented.load(Ordering::Relaxed),
        bytes: sh.stats.bytes.load(Ordering::Relaxed),
        decode_us: sh.stats.decode_us_total.load(Ordering::Relaxed),
    };
    let prev = STATE.with(|s| s.borrow_mut().stats_last.replace(now));
    let cfg = *sh.config.lock().unwrap();
    let host_name = sh.host_name.lock().unwrap().clone();
    let status = sh.status.lock().unwrap().clone();
    let (vw, vh, _) = *sh.view.lock().unwrap();
    let kb_released = STATE.with(|s| s.borrow().kb_released);
    // Outside the literal below: its `sh.clock` guard temporary lives until the end of the
    // statement, and latency_tick() locks `sh.clock` too.
    let latency = latency_tick();
    let info = hud::HudInfo {
        host_name: host_name.clone(),
        status: status.clone(),
        video: (cfg.width, cfg.height),
        codec: cfg.codec.name().to_string(),
        chroma: cfg.chroma_name().to_string(),
        decoder: sh.decoder_desc.lock().unwrap().clone(),
        rates: prev.map(|p| hud::rates(&p, &now)).unwrap_or_default(),
        rtt_ms: sh.clock.lock().unwrap().as_ref().and_then(|c| c.lock().unwrap().last_rtt_ms),
        mode: Some(current_mode()),
        showing_sharp: sh.stats.showing_sharp.load(Ordering::Relaxed) == 1,
        sharp_frames: sh.stats.sharp.load(Ordering::Relaxed),
        rect_frames: sh.stats.rect_frames.load(Ordering::Relaxed),
        decode_errors: sh.stats.decode_errors.load(Ordering::Relaxed),
        view: (vw, vh),
        keyboard_captured: !kb_released,
        audio: audio_hud(),
        latency,
        latency_test: sh.latency_test.load(Ordering::Relaxed),
        mac_display: {
            // "DELL U2723QE · 1920×1080 Retina (automatic)": which Mac display (§3.5) and its mode (§3.3).
            let name = sh.displays.lock().unwrap().as_ref().map(|d| d.name(d.streamed));
            let mode = sh.display_info.lock().unwrap().map(|d| format!("{} ({})", d.describe(), menu_model::display_pref_name(d.preference)));
            match (name, mode) {
                (Some(n), Some(m)) => Some(format!("{n} · {m}")),
                (n, m) => n.or(m),
            }
            .filter(|_| status.is_none())
        },
    };
    let lines = hud::lines(&info);
    let hud_on = STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.last_hud = lines.clone();
        s.hud_on
    });
    render_cmd(RenderCmd::Hud(hud_on.then_some(lines)));
    // File transfer progress: keep a toast line up while transfers run (this runs every 500 ms).
    if let Some(line) = files::progress_line() {
        toast(line);
    }

    // Title: just who we're looking at (stats live in the HUD, Ctrl+Alt+Shift+H).
    let mut t = match &status {
        Some(st) => format!("Glide — {st}"),
        None => format!("{host_name} — Glide"),
    };
    if kb_released && status.is_none() {
        t.push_str(" — keyboard released (Ctrl+Alt+Shift+K)");
    }
    let changed = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let c = s.last_title != t;
        s.last_title = t.clone();
        c
    });
    if changed {
        let wide: Vec<u16> = t.encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = SetWindowTextW(hwnd, PCWSTR(wide.as_ptr()));
        }
        if let Some(tr) = STATE.with(|s| s.borrow().tray.clone()) {
            tr.set_tip(&t);
        }
    }
}

/// Finalize latency records, send the viewer's breakdown to the host every 2 s (§3.4), and in
/// test mode log it every 10 s. Returns the HUD summary once the host sends FrameTiming.
fn latency_tick() -> Option<crate::latency::Summary> {
    let sh = &ui().shared;
    let clock = sh.clock.lock().unwrap().clone();
    let mut l = sh.latency.lock().unwrap();
    match &clock {
        Some(c) => {
            let c = c.lock().unwrap();
            l.tick(now_us(), c.offset_us.is_some().then_some(&*c));
            *sh.clock_info.lock().unwrap() = format!(
                "{{\"min_rtt_ms\":{},\"drift_ppm\":{:.2},\"window_samples\":{}}}",
                crate::util::json_opt(c.min_rtt_us().map(|u| u as f64 / 1000.0)),
                c.drift_ppm(),
                c.window_samples()
            );
        }
        None => l.tick(now_us(), None),
    }
    if !l.host_timing_seen {
        return None;
    }
    let summary = l.summary();
    let report = l.report();
    drop(l);
    let (send_report, log) = STATE.with(|s| {
        let mut s = s.borrow_mut();
        let due = |t: &mut Option<Instant>, every: u64| {
            let d = t.is_none_or(|t| t.elapsed() >= Duration::from_secs(every));
            if d {
                *t = Some(Instant::now());
            }
            d
        };
        (due(&mut s.last_latency_report, 2), due(&mut s.last_latency_log, 10))
    });
    if send_report && summary.n > 0 {
        send(ClientMsg::LatencyReport(report));
    }
    if log && sh.latency_test.load(Ordering::Relaxed) {
        eprintln!("latency: {}", hud::latency_lines(&summary, true).join(" | "));
    }
    Some(summary)
}

/// Write the latency test report (all samples since the test started) and return its path.
fn write_latency_report() -> Option<String> {
    let sh = &ui().shared;
    let clock = sh.clock.lock().unwrap().clone();
    let clock_json = sh.clock_info.lock().unwrap().clone();
    let cfg = *sh.config.lock().unwrap();
    let mut l = sh.latency.lock().unwrap();
    if let Some(c) = &clock {
        let c = c.lock().unwrap();
        l.tick(now_us() + crate::latency::SCANOUT_WAIT_US, c.offset_us.is_some().then_some(&*c));
    }
    let json = format!(
        "{{\"host\":{},\"video\":\"{}x{} {} {}\",\"mode\":\"{}\",\"present\":{},\"clock\":{},\"latency\":{}}}",
        crate::util::json_str(&sh.host_name.lock().unwrap()),
        cfg.width,
        cfg.height,
        cfg.codec.name(),
        cfg.chroma_name(),
        current_mode().name(),
        sh.present_info.lock().unwrap(),
        clock_json,
        l.report_json()
    );
    drop(l);
    eprintln!("latency report: {json}");
    let path = std::env::var("GLIDE_LATENCY_OUT").unwrap_or_else(|_| {
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        std::env::temp_dir().join(format!("glide-latency-{secs}.json")).to_string_lossy().into_owned()
    });
    match std::fs::write(&path, json + "\n") {
        Ok(()) => Some(path),
        Err(e) => {
            eprintln!("latency report: cannot write {path}: {e}");
            None
        }
    }
}

fn set_latency_test(on: bool) {
    let sh = &ui().shared;
    sh.latency_test.store(on, Ordering::Relaxed);
    let mut l = sh.latency.lock().unwrap();
    l.keep_all = on;
    if on {
        l.all.clear();
        l.all_gt.clear();
    }
}

fn toast(text: impl Into<String>) {
    render_cmd(RenderCmd::Toast(text.into()));
}

/// Run a hotkey / tray / test action on the UI thread.
fn do_action(hwnd: HWND, a: Action) {
    let sh = &ui().shared;
    match a {
        Action::ToggleHud => {
            let on = STATE.with(|s| {
                let mut s = s.borrow_mut();
                s.hud_on = !s.hud_on;
                s.hud_on
            });
            ui().store.lock().unwrap().update(|c| c.hud = on);
            update_title(hwnd);
            toast(if on { "Stats overlay on" } else { "Stats overlay off" });
        }
        Action::CycleMode => {
            let cur = current_mode();
            let next = hotkeys::next_mode(cur, sh.has444);
            if next == cur {
                toast("Only Fast mode — this PC can't decode HEVC 4:4:4");
                return;
            }
            set_mode(hwnd, next);
        }
        Action::OpenMenu => open_menu(hwnd, menu::Anchor::Cursor),
        Action::ToggleFullscreen => {
            toggle_fullscreen(hwnd);
            schedule_view_check(hwnd);
            remember_placement(hwnd);
            toast(if is_fullscreen() { "Fullscreen — F11 or Ctrl+Alt+Shift+F to exit" } else { "Windowed" });
        }
        Action::ToggleKeyboardCapture => {
            let released = STATE.with(|s| {
                let mut s = s.borrow_mut();
                s.kb_released = !s.kb_released;
                s.kb_released
            });
            if released {
                remove_hook();
                // Modifiers of the hotkey itself (and anything else held) were forwarded as downs.
                send(ClientMsg::ReleaseAll);
                toast("Keyboard released — shortcuts go to Windows · Ctrl+Alt+Shift+K to recapture");
            } else {
                if STATE.with(|s| s.borrow().focused) {
                    install_hook();
                }
                toast("Keyboard captured — shortcuts go to the Mac");
            }
            update_title(hwnd);
        }
        Action::RequestKeyframe => {
            if connected() {
                send(ClientMsg::RequestKeyframe);
                toast("Keyframe requested");
            } else {
                toast("Not connected");
            }
        }
        Action::ToggleMute => toggle_mute(hwnd),
        Action::PullFiles => toast(files::pull()),
        Action::CancelFiles => toast(files::cancel()),
        Action::NextDisplay => cycle_display(1),
        Action::PrevDisplay => cycle_display(-1),
        Action::LatencyTest => {
            if sh.latency_test.load(Ordering::Relaxed) {
                let path = write_latency_report();
                set_latency_test(false);
                toast(match path {
                    Some(p) => format!("Latency test off — report: {p}"),
                    None => "Latency test off".to_string(),
                });
            } else {
                set_latency_test(true);
                // The breakdown is in the HUD: make sure it's visible.
                if !STATE.with(|s| s.borrow().hud_on) {
                    do_action(hwnd, Action::ToggleHud);
                }
                toast("Latency test on — run glide-probe --pattern-only on the Mac · Ctrl+Alt+Shift+L to stop");
            }
            update_title(hwnd);
        }
        Action::Reconnect => {
            sh.paused.store(false, Ordering::Relaxed);
            let cur = sh.sender.lock().unwrap().clone();
            match cur {
                Some(s) => {
                    sh.reconnect.store(true, Ordering::Relaxed);
                    let _ = s.send(&ClientMsg::ReleaseAll);
                    s.shutdown();
                    toast("Reconnecting…");
                }
                None => toast("Not connected — retrying"),
            }
        }
    }
}

/// Ctrl+Alt+Shift+→/←: stream the next/previous Mac display (§3.5). The host answers with
/// DisplayChanged, whose toast replaces this one.
fn cycle_display(step: i32) {
    if !connected() {
        toast("Not connected");
        return;
    }
    let st = ui().shared.displays.lock().unwrap().clone();
    match st {
        None => toast("This Mac can't switch displays — update Glide Host"),
        Some(st) => match st.cycle(step) {
            Some(id) => select_display(id, &st),
            None => toast(format!("The Mac has one display (“{}”)", st.name(st.streamed))),
        },
    }
}

/// Ask the host to stream display `id` (0 = its default).
fn select_display(id: u32, st: &DisplayState) {
    eprintln!("display: SelectDisplay {id}");
    send(ClientMsg::SelectDisplay { display_id: id });
    toast(if id == 0 { "Switching to the Mac's main display…".to_string() } else { format!("Switching to “{}”…", st.name(id)) });
}

/// Switch the stream mode (SetMode), remembered in the config and used for reconnects.
fn set_mode(hwnd: HWND, next: Mode) {
    let sh = &ui().shared;
    if next != Mode::Fast && !sh.has444 {
        toast("Only Fast mode — this PC can't decode HEVC 4:4:4");
        return;
    }
    sh.mode.store(next as u8, Ordering::Relaxed);
    sh.stats.showing_sharp.store(0, Ordering::Relaxed);
    ui().store.lock().unwrap().update(|c| c.set_mode(next));
    if connected() {
        eprintln!("mode -> {} (SetMode)", next.name());
        send(ClientMsg::SetMode { mode: next as u8, bitrate_kbps: 0, max_fps: 0 });
        toast(format!("Mode: {}", hotkeys::mode_label(next)));
    } else {
        toast(format!("Mode: {} — applies when connected", hotkeys::mode_label(next)));
    }
    update_title(hwnd);
}

// ------------------------------------------------------------------ context menu

fn menu_state() -> menu_model::MenuState {
    let sh = &ui().shared;
    STATE.with(|s| {
        let s = s.borrow();
        menu_model::MenuState {
            host_name: sh.host_name.lock().unwrap().clone(),
            connected: connected(),
            paused: sh.paused.load(Ordering::Relaxed),
            mode: Some(current_mode()),
            has444: sh.has444,
            display: *sh.display_info.lock().unwrap(),
            audio_muted: sh.audio.as_ref().map(|a| a.muted()),
            clipboard_on: clipboard::is_active(),
            hud: s.hud_on,
            fullscreen: s.fullscreen_saved.is_some(),
            keyboard_released: s.kb_released,
            bar_pinned: cbar::pinned(),
            files_on: files::enabled(),
            file_transfer: files::peer_flags().is_some_and(|f| f & protocol::FILE_CAPS_RECEIVE != 0),
            file_pull: files::peer_flags().is_some_and(|f| f & protocol::FILE_CAPS_SEND != 0),
            files_busy: files::busy(),
            latency_test: sh.latency_test.load(Ordering::Relaxed),
            displays: sh.displays.lock().unwrap().clone(),
        }
    })
}

/// Show the Glide menu (connection bar click, Ctrl+Alt+Shift+Space) and run the choice.
fn open_menu(hwnd: HWND, anchor: menu::Anchor) {
    // Held modifiers (e.g. from Ctrl+Alt+Shift+Space) were forwarded: release them on the Mac.
    if connected() {
        send(ClientMsg::ReleaseAll);
    }
    cbar::hold(hwnd);
    let items = menu_model::build(&menu_state());
    MENU_OPEN.store(true, Ordering::Relaxed);
    let choice = menu::track(hwnd, &items, anchor);
    MENU_OPEN.store(false, Ordering::Relaxed);
    cbar::release(hwnd);
    if let Some(c) = choice {
        run_menu_cmd(hwnd, c);
    }
}

/// A command from the context menu, the system menu or the test hook.
fn run_menu_cmd(hwnd: HWND, c: Cmd) {
    eprintln!("menu: {}", c.name());
    if let Some(m) = c.mode() {
        if m != current_mode() {
            set_mode(hwnd, m);
        }
        return;
    }
    if let Some(p) = c.display_pref() {
        if connected() {
            send(ClientMsg::SetDisplayPreference { mode: p });
            toast(format!("Mac display: {}", menu_model::display_pref_name(p)));
        }
        return;
    }
    if let Some(keys) = menu_model::mac_shortcut(c) {
        if connected() {
            send(ClientMsg::ReleaseAll);
            for (usage, down) in keys {
                send(ClientMsg::Key { hid_usage: usage, down });
            }
        }
        return;
    }
    match c {
        Cmd::ToggleMute => toggle_mute(hwnd),
        Cmd::ToggleClipboard => toggle_clipboard(hwnd),
        Cmd::ToggleHud => do_action(hwnd, Action::ToggleHud),
        Cmd::LatencyTest => do_action(hwnd, Action::LatencyTest),
        Cmd::ToggleFullscreen => do_action(hwnd, Action::ToggleFullscreen),
        Cmd::ToggleKeyboard => do_action(hwnd, Action::ToggleKeyboardCapture),
        Cmd::RefreshPicture => do_action(hwnd, Action::RequestKeyframe),
        Cmd::Reconnect => do_action(hwnd, Action::Reconnect),
        Cmd::Disconnect => set_paused(hwnd, true),
        Cmd::Connect => set_paused(hwnd, false),
        Cmd::PinBar => {
            let pinned = !cbar::pinned();
            cbar::set_pinned(hwnd, pinned);
            ui().store.lock().unwrap().update(|c| c.bar_pinned = pinned);
            toast(if pinned { "Connection bar pinned" } else { "Connection bar unpinned" });
        }
        Cmd::Settings => match ui().store.lock().unwrap().path() {
            Some(p) => tray::open_in_editor(&p),
            None => toast("No config file (APPDATA not set)"),
        },
        Cmd::OpenMenu => open_menu(hwnd, menu::Anchor::Cursor),
        Cmd::SendFiles | Cmd::SendFolder => {
            if let Some(t) = files::pick_and_send(hwnd, c == Cmd::SendFolder) {
                toast(t);
            }
        }
        Cmd::ReceiveFiles => do_action(hwnd, Action::PullFiles),
        Cmd::CancelFiles => do_action(hwnd, Action::CancelFiles),
        Cmd::OpenReceived => files::open_folder(),
        Cmd::ShowDefaultDisplay | Cmd::ShowDisplay(_) => {
            let Some(st) = ui().shared.displays.lock().unwrap().clone().filter(|_| connected()) else { return };
            match c {
                Cmd::ShowDisplay(i) => match st.displays.get(i as usize) {
                    Some(d) => select_display(d.id, &st),
                    None => toast("That Mac display is gone"),
                },
                _ => select_display(0, &st),
            }
        }
        _ => {}
    }
}

/// Menu → Clipboard sync: on/off at runtime, persisted. Turning it on mid-session reconnects if
/// this connection didn't negotiate clipboard sync (ClientHello only advertises it while on).
fn toggle_clipboard(hwnd: HWND) {
    let on = !clipboard::is_active();
    clipboard::set_active(hwnd, on);
    ui().store.lock().unwrap().update(|c| c.clipboard = on);
    if on && connected() && !clipboard::negotiated() {
        toast("Clipboard sync on — reconnecting to enable it");
        do_action(hwnd, Action::Reconnect);
    } else {
        toast(if on { "Clipboard sync on" } else { "Clipboard sync off" });
    }
}

/// Tray "Disconnect" / "Connect".
fn set_paused(hwnd: HWND, paused: bool) {
    let sh = &ui().shared;
    sh.paused.store(paused, Ordering::Relaxed);
    if paused {
        sh.abort_accept.store(true, Ordering::Relaxed);
        if let Some(s) = sh.sender.lock().unwrap().clone() {
            let _ = s.send(&ClientMsg::ReleaseAll);
            s.shutdown();
        }
        toast("Disconnected");
    } else {
        toast("Connecting…");
    }
    update_title(hwnd);
}

/// Save the window's normal rect, maximized and fullscreen state for its current monitor.
fn remember_placement(hwnd: HWND) {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            return;
        }
        let Some(mon) = placement::monitor_desc(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)) else { return };
        let (fs, saved_wp, normal) = STATE.with(|s| {
            let s = s.borrow();
            (s.fullscreen_saved.is_some(), s.fullscreen_saved.map(|f| f.1), s.normal_rect)
        });
        let maximized = match saved_wp {
            Some(wp) => wp.showCmd == SW_SHOWMAXIMIZED.0 as u32,
            None => IsZoomed(hwnd).as_bool(),
        };
        let normal = match normal {
            Some(r) => r,
            None => {
                let mut r = RECT::default();
                let _ = GetWindowRect(hwnd, &mut r);
                r
            }
        };
        ui().store.lock().unwrap().update(|c| {
            config::record_placement(c, &mon, placement::rect(normal), maximized, fs);
        });
    }
}

/// Track the normal (restored, windowed) rect as the window moves/resizes.
fn track_normal_rect(hwnd: HWND) {
    unsafe {
        if is_fullscreen() || IsIconic(hwnd).as_bool() || IsZoomed(hwnd).as_bool() {
            return;
        }
        let mut r = RECT::default();
        if GetWindowRect(hwnd, &mut r).is_ok() {
            STATE.with(|s| s.borrow_mut().normal_rect = Some(r));
        }
    }
}

/// Session thread → UI thread: show the pairing dialog, answer on `reply`.
struct PairRequest {
    prompt: PairPrompt,
    cancel: Arc<AtomicBool>,
    reply: mpsc::Sender<bool>,
}

/// `PairingUi` for the GUI: the dialog runs modally on the UI thread (WM_APP_PAIR); the
/// session thread blocks in `confirm` until it is answered or dismissed.
struct GuiPairing {
    hwnd: isize,
    cancel: Mutex<Option<Arc<AtomicBool>>>,
}

impl PairingUi for GuiPairing {
    fn confirm(&self, p: &PairPrompt) -> bool {
        let cancel = Arc::new(AtomicBool::new(false));
        *self.cancel.lock().unwrap() = Some(cancel.clone());
        let (tx, rx) = mpsc::channel();
        let req = Box::into_raw(Box::new(PairRequest { prompt: p.clone(), cancel: cancel.clone(), reply: tx }));
        let posted = unsafe { PostMessageW(Some(HWND(self.hwnd as *mut _)), WM_APP_PAIR, WPARAM(0), LPARAM(req as isize)) };
        if posted.is_err() {
            drop(unsafe { Box::from_raw(req) });
            return false;
        }
        loop {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(v) => return v && !cancel.load(Ordering::SeqCst),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if UI.get().is_some_and(|u| u.shared.quit.load(Ordering::Relaxed)) {
                        cancel.store(true, Ordering::SeqCst);
                        return false;
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return false,
            }
        }
    }

    fn dismiss(&self) {
        if let Some(c) = self.cancel.lock().unwrap().as_ref() {
            c.store(true, Ordering::SeqCst);
        }
    }
}

/// WM_APP_PAIR: show the pairing dialog for the session thread's request.
fn show_pairing(hwnd: HWND, req: PairRequest) {
    let p = &req.prompt;
    set_focus_state(hwnd, false); // the LL keyboard hook must not swallow the dialog's keys
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
    }
    let text = PairText {
        text: format!("Pair this PC with the Glide host at {}?\nThe Mac shows a code too. Only continue if both codes are the same.", p.target),
        code: p.code.clone(),
        detail: format!(
            "Confirm on the Mac as well. Mac key: {}\nThis PC's key: {}\nIf the codes differ, click Cancel: something is intercepting the connection.",
            p.host_fingerprint, p.viewer_fingerprint
        ),
    };
    let ok = match prompt::ask_pairing(Some(hwnd), text, req.cancel.clone()) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            false
        }
    };
    eprintln!("pairing dialog: {}", if ok { "codes match" } else { "cancelled" });
    let _ = req.reply.send(ok);
    if unsafe { GetForegroundWindow() } == hwnd {
        set_focus_state(hwnd, true);
    }
}

/// Tray "Forget host (unpair)…": after a confirmation, forget the pinned host key (and the
/// TOFU IP pin) and drop the connection; the next connection pairs again.
fn forget_host(hwnd: HWND) {
    let target = ui().shared.pin_target.clone();
    let name = ui().store.lock().unwrap().config.pinned_hosts.get(&target).map(|p| p.name.clone());
    let Some(name) = name else {
        toast("Not paired");
        return;
    };
    let msg = format!(
        "Forget the Mac “{name}” ({target})?\n\nThis PC will no longer trust its key. To connect again you must pair again: on the Mac choose Glide → Pair New Viewer…, then compare the code on both screens.\n\nAlso remove this PC on the Mac (Glide → Paired Viewers) if you are retiring it."
    );
    let w: Vec<u16> = msg.encode_utf16().chain(std::iter::once(0)).collect();
    let r = unsafe { MessageBoxW(Some(hwnd), PCWSTR(w.as_ptr()), w!("Glide — Forget host"), MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) };
    if r != IDYES {
        return;
    }
    let had = ui().store.lock().unwrap().forget_host(&target);
    if ui().shared.listening {
        let mut old = Vec::new();
        ui().store.lock().unwrap().update(|c| old = std::mem::take(&mut c.allowed_peers));
        if !old.is_empty() {
            eprintln!("also forgot pinned host IPs {old:?}");
        }
    }
    eprintln!("unpaired {target}: {:?}", had.map(|p| p.key));
    ui().shared.repair.store(false, Ordering::Relaxed);
    if let Some(s) = ui().shared.sender.lock().unwrap().clone() {
        ui().shared.reconnect.store(true, Ordering::Relaxed);
        let _ = s.send(&ClientMsg::ReleaseAll);
        s.shutdown();
    }
    toast(format!("Forgot “{name}” — pair again from the Mac (Pair New Viewer…)"));
}

/// Mute/unmute: stops local playback and tells the host to stop/start sending (AudioEnable).
/// Persisted in the config (`audio_muted`).
fn toggle_mute(hwnd: HWND) {
    let Some(a) = &ui().shared.audio else {
        toast("Audio is off (--no-audio or config \"audio\": false)");
        return;
    };
    let muted = a.set_muted(!a.muted());
    eprintln!("audio: {}", if muted { "muted" } else { "unmuted" });
    send(ClientMsg::AudioEnable { enabled: !muted });
    ui().store.lock().unwrap().update(|c| c.audio_muted = muted);
    toast(if muted { "Audio muted" } else { "Audio on" });
    update_title(hwnd);
}

fn audio_hud() -> Option<hud::AudioHud> {
    let a = ui().shared.audio.as_ref()?;
    let st = a.status();
    let muted = a.muted();
    Some(hud::AudioHud {
        muted,
        // status_text() is empty exactly when no AudioConfig has arrived (and not muted).
        streaming: muted || !a.status_text().is_empty(),
        e2e_ms: st.e2e_ms,
        buffer_ms: st.jitter_ms + st.device_ms,
        underruns: st.underruns,
        error: st.error.clone(),
    })
}

fn render_cmd(c: RenderCmd) {
    let _ = ui().render_tx.lock().unwrap().send(c);
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if UI.get().is_none() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    match msg {
        WM_SIZE => {
            let (w, h) = ((lparam.0 & 0xFFFF) as u32, ((lparam.0 >> 16) & 0xFFFF) as u32);
            if w > 0 && h > 0 {
                render_cmd(RenderCmd::Resize(w, h));
            }
            schedule_view_check(hwnd);
            track_normal_rect(hwnd);
            SetTimer(Some(hwnd), PLACEMENT_TIMER, 1000, None);
            LRESULT(0)
        }
        WM_MOVE | WM_DISPLAYCHANGE | WM_EXITSIZEMOVE => {
            schedule_view_check(hwnd);
            track_normal_rect(hwnd);
            SetTimer(Some(hwnd), PLACEMENT_TIMER, 1000, None);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_TIMER if wparam.0 == VIEW_TIMER => {
            let _ = KillTimer(Some(hwnd), VIEW_TIMER);
            check_view(hwnd);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == PLACEMENT_TIMER => {
            let _ = KillTimer(Some(hwnd), PLACEMENT_TIMER);
            remember_placement(hwnd);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TEST_ACTION_TIMER => {
            match STATE.with(|s| s.borrow_mut().test_actions.pop()) {
                Some(step) => {
                    eprintln!("test action: {step:?}");
                    match step {
                        TestStep::Action(a) => do_action(hwnd, a),
                        TestStep::Menu(c) => run_menu_cmd(hwnd, c),
                        TestStep::Bar => cbar::reveal(hwnd),
                    }
                }
                None => {
                    let _ = KillTimer(Some(hwnd), TEST_ACTION_TIMER);
                }
            }
            LRESULT(0)
        }
        WM_APP_HOTKEY => {
            if let Some(a) = Action::from_u8(wparam.0 as u8) {
                do_action(hwnd, a);
            }
            LRESULT(0)
        }
        WM_APP_PAIR => {
            if lparam.0 != 0 {
                let req = *Box::from_raw(lparam.0 as *mut PairRequest);
                show_pairing(hwnd, req);
            }
            LRESULT(0)
        }
        WM_APP_TRAY if (lparam.0 & 0xFFFF) as u32 == windows::Win32::UI::Shell::NIN_BALLOONUSERCLICK => {
            if STATE.with(|s| s.borrow().balloon_shows_files) {
                files::open_folder();
            }
            LRESULT(0)
        }
        WM_APP_TRAY => {
            let st = tray::MenuState {
                audio: ui().shared.audio.as_ref().map(|a| a.muted()),
                paused: ui().shared.paused.load(Ordering::Relaxed),
                hud_on: STATE.with(|s| s.borrow().hud_on),
                paired: ui().store.lock().unwrap().config.pinned_hosts.get(&ui().shared.pin_target).map(|p| p.name.clone()),
                files: files::enabled().then(files::busy),
            };
            tray::on_notify(hwnd, lparam, &st);
            LRESULT(0)
        }
        WM_COMMAND if lparam.0 == 0 && tray::is_menu_id((wparam.0 & 0xFFFF) as u16) => {
            match tray::MenuCmd::from_id((wparam.0 & 0xFFFF) as u16) {
                Some(tray::MenuCmd::Connect) => set_paused(hwnd, false),
                Some(tray::MenuCmd::Disconnect) => set_paused(hwnd, true),
                Some(tray::MenuCmd::Reconnect) => do_action(hwnd, Action::Reconnect),
                Some(tray::MenuCmd::ToggleHud) => do_action(hwnd, Action::ToggleHud),
                Some(tray::MenuCmd::OpenConfig) => {
                    let path = ui().store.lock().unwrap().path();
                    match path {
                        Some(p) => tray::open_in_editor(&p),
                        None => toast("No config file (APPDATA not set)"),
                    }
                }
                Some(tray::MenuCmd::ToggleMute) => toggle_mute(hwnd),
                Some(tray::MenuCmd::ForgetHost) => forget_host(hwnd),
                Some(tray::MenuCmd::CancelFiles) => do_action(hwnd, Action::CancelFiles),
                Some(tray::MenuCmd::OpenDownloads) => files::open_folder(),
                Some(tray::MenuCmd::Quit) => {
                    let _ = DestroyWindow(hwnd);
                }
                None => {}
            }
            LRESULT(0)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            BeginPaint(hwnd, &mut ps);
            let _ = EndPaint(hwnd, &ps);
            render_cmd(RenderCmd::Redraw);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_MOUSEMOVE => {
            mouse_move(hwnd, lparam);
            LRESULT(0)
        }
        WM_LBUTTONDOWN | WM_LBUTTONDBLCLK => {
            button(hwnd, lparam, protocol::MOUSE_LEFT, true);
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            button(hwnd, lparam, protocol::MOUSE_LEFT, false);
            LRESULT(0)
        }
        WM_RBUTTONDOWN | WM_RBUTTONDBLCLK => {
            button(hwnd, lparam, protocol::MOUSE_RIGHT, true);
            LRESULT(0)
        }
        WM_RBUTTONUP => {
            button(hwnd, lparam, protocol::MOUSE_RIGHT, false);
            LRESULT(0)
        }
        WM_MBUTTONDOWN | WM_MBUTTONDBLCLK => {
            button(hwnd, lparam, protocol::MOUSE_MIDDLE, true);
            LRESULT(0)
        }
        WM_MBUTTONUP => {
            button(hwnd, lparam, protocol::MOUSE_MIDDLE, false);
            LRESULT(0)
        }
        WM_XBUTTONDOWN | WM_XBUTTONDBLCLK | WM_XBUTTONUP => {
            let x = ((wparam.0 >> 16) & 0xFFFF) as u16;
            let b = if x == XBUTTON1 { protocol::MOUSE_BACK } else { protocol::MOUSE_FORWARD };
            button(hwnd, lparam, b, msg != WM_XBUTTONUP);
            LRESULT(1)
        }
        WM_MOUSEWHEEL | WM_MOUSEHWHEEL if cbar::cursor_hit(hwnd) => LRESULT(0),
        WM_MOUSEWHEEL | WM_MOUSEHWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xFFFF) as u16 as i16 as f32 / 120.0;
            if msg == WM_MOUSEWHEEL {
                // Positive = wheel rotated away from the user = scroll up = dy > 0.
                send(ClientMsg::MouseWheel { dx: 0.0, dy: delta });
            } else {
                // Positive = tilted right = dx > 0.
                send(ClientMsg::MouseWheel { dx: delta, dy: 0.0 });
            }
            LRESULT(0)
        }
        WM_SETCURSOR => {
            if (lparam.0 & 0xFFFF) as u32 == HTCLIENT {
                let mut pt = POINT::default();
                let _ = GetCursorPos(&mut pt);
                let _ = ScreenToClient(hwnd, &mut pt);
                let (x, y, w, h) = video_rect(hwnd);
                let inside = pt.x >= x && pt.x < x + w && pt.y >= y && pt.y < y + h;
                if inside && !cbar::hit(hwnd, pt.x, pt.y) {
                    SetCursor(current_cursor(hwnd));
                } else {
                    SetCursor(LoadCursorW(None, IDC_ARROW).ok());
                }
                return LRESULT(1);
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_ACTIVATE => {
            let active = (wparam.0 & 0xFFFF) as u32 != WA_INACTIVE;
            set_focus_state(hwnd, active);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_KILLFOCUS => {
            set_focus_state(hwnd, false);
            LRESULT(0)
        }
        WM_SETFOCUS => {
            set_focus_state(hwnd, true);
            LRESULT(0)
        }
        // Fallback keyboard path (only reached if the LL hook isn't installed).
        WM_KEYDOWN | WM_KEYUP | WM_SYSKEYDOWN | WM_SYSKEYUP => {
            let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let sc = hid::scancode_from_lparam(lparam.0);
            if handle_key(hwnd, wparam.0 as u32, (sc & 0xFF) as u32, sc & hid::EXT != 0, down) {
                LRESULT(0)
            } else {
                DefWindowProcW(hwnd, msg, wparam, lparam)
            }
        }
        WM_SYSCHAR | WM_CHAR => LRESULT(0),
        // Alt alone must not enter menu mode (it's Option on the Mac); Alt+Space (keyboard
        // released) opens the system menu as usual.
        WM_SYSCOMMAND if (wparam.0 & 0xFFF0) as u32 == SC_KEYMENU && lparam.0 != 0x20 => LRESULT(0),
        WM_ENTERMENULOOP => {
            MENU_OPEN.store(true, Ordering::Relaxed);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_EXITMENULOOP => {
            MENU_OPEN.store(false, Ordering::Relaxed);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_SYSCOMMAND if Cmd::from_id((wparam.0 & 0xFFF0) as u32).is_some() => {
            run_menu_cmd(hwnd, Cmd::from_id((wparam.0 & 0xFFF0) as u32).unwrap());
            LRESULT(0)
        }
        WM_INITMENU => {
            // The system menu is about to open: refresh the Glide items' check marks.
            menu::refresh_system_menu(hwnd, &menu_model::system_items(&menu_state()));
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == cbar::BAR_TIMER => {
            cbar::on_timer(hwnd);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TITLE_TIMER => {
            update_title(hwnd);
            LRESULT(0)
        }
        WM_TIMER if clipboard::is_timer(wparam.0) => {
            clipboard::on_timer(hwnd, wparam.0);
            LRESULT(0)
        }
        WM_CLIPBOARDUPDATE => {
            clipboard::on_clipboard_update(hwnd);
            LRESULT(0)
        }
        clipboard::WM_APP_CLIPBOARD => {
            clipboard::on_app_clipboard(hwnd);
            LRESULT(0)
        }
        WM_DROPFILES => {
            if let Some(t) = files::on_drop(windows::Win32::UI::Shell::HDROP(wparam.0 as *mut _)) {
                toast(t);
            }
            LRESULT(0)
        }
        files::WM_APP_FILES => {
            let tray = STATE.with(|s| s.borrow().tray.clone());
            for n in files::take_notices() {
                eprintln!("files: {}", n.toast);
                toast(n.toast);
                if let (Some((title, body)), Some(t)) = (n.balloon, &tray) {
                    STATE.with(|s| s.borrow_mut().balloon_shows_files = title.starts_with("Received"));
                    t.notify(&title, &body);
                }
            }
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == EXIT_TIMER => {
            if std::env::var("GLIDE_DUMP_MENU").as_deref() == Ok("1") {
                // Test hook: the menu as text (session 0 can't show real menus).
                let st = menu_state();
                eprintln!("context menu:\n{}", menu_model::to_text(&menu_model::build(&st)));
                eprintln!("system menu additions:\n{}", menu_model::to_text(&menu_model::system_items(&st)));
            }
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DPICHANGED => {
            let r = &*(lparam.0 as *const RECT);
            let _ = SetWindowPos(hwnd, None, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
            schedule_view_check(hwnd);
            LRESULT(0)
        }
        WM_APP_CURSOR => {
            apply_cursor_if_inside(hwnd);
            LRESULT(0)
        }
        WM_APP_CLOSED => {
            update_title(hwnd);
            LRESULT(0)
        }
        WM_APP_DISCONNECTED => {
            // No stuck keys/buttons: drop all local held state (the host side is gone anyway).
            release_all(hwnd);
            let host = ui().shared.host_name.lock().unwrap().clone();
            cbar::set_label(hwnd, &format!("{host} — disconnected"));
            {
                let mut c = ui().shared.cursor.lock().unwrap();
                c.visible = true;
            }
            apply_cursor_if_inside(hwnd);
            update_title(hwnd);
            LRESULT(0)
        }
        WM_APP_CONNECTED => {
            // A new host process may reuse cursor shape ids: drop cached HCURSORs.
            STATE.with(|s| {
                let mut s = s.borrow_mut();
                for (_, c) in s.cursor_cache.drain() {
                    destroy_cursor(c);
                }
                s.keys_down.clear();
                s.swallow_up.clear();
                s.last_move = None;
                s.stats_last = None;
            });
            // The hello carried the view at connect time; re-check in case the window moved since.
            check_view(hwnd);
            apply_cursor_if_inside(hwnd);
            update_title(hwnd);
            let host = ui().shared.host_name.lock().unwrap().clone();
            cbar::set_label(hwnd, &host);
            let paired = ui().shared.just_paired.lock().unwrap().take();
            match (paired, ui().shared.just_pinned.lock().unwrap().take()) {
                (Some(fp), _) => toast(format!("Paired with {host} (key {fp}) — connected")),
                (None, Some(ip)) => toast(format!("Connected to {host} · pinned host {ip}")),
                (None, None) => toast(format!("Connected to {host}")),
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            set_focus_state(hwnd, false);
            remember_placement(hwnd);
            if let Some(t) = STATE.with(|s| s.borrow_mut().tray.take()) {
                t.remove();
            }
            clipboard::shutdown(hwnd);
            PostQuitMessage(0);
            LRESULT(0)
        }
        m if m == tray::taskbar_created_msg() => {
            // Explorer restarted: re-add the tray icon.
            if let Some(t) = STATE.with(|s| s.borrow().tray.clone()) {
                t.add();
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Initial window client size: the video at 1:1 if it fits in ~90% of the work area,
/// otherwise aspect-fit into it.
fn initial_client_size(vw: u32, vh: u32) -> (i32, i32) {
    unsafe {
        let mut wa = RECT::default();
        let _ = SystemParametersInfoW(SPI_GETWORKAREA, 0, Some(&mut wa as *mut _ as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0));
        let aw = ((wa.right - wa.left) as f32 * 0.9) as u32;
        let ah = ((wa.bottom - wa.top) as f32 * 0.9) as u32;
        if vw <= aw && vh <= ah {
            (vw as i32, vh as i32)
        } else {
            let (_, _, w, h) = letterbox(aw.max(320), ah.max(240), vw.max(1), vh.max(1));
            (w, h)
        }
    }
}

fn post(hwnd_raw: isize, m: u32) {
    unsafe {
        let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), m, WPARAM(0), LPARAM(0));
    }
}

fn set_status(shared: &Shared, tx: &mpsc::Sender<RenderCmd>, hwnd_raw: isize, text: Option<String>) {
    let changed = {
        let mut st = shared.status.lock().unwrap();
        let c = *st != text;
        *st = text.clone();
        c
    };
    if changed {
        if let Some(t) = &text {
            eprintln!("status: {t}");
        }
        let _ = tx.send(RenderCmd::Status(text));
        post(hwnd_raw, WM_APP_CLOSED); // refresh title
    }
}

/// Sleep up to `d`, returning early (true) if quit was requested.
fn sleep_or_quit(shared: &Shared, d: Duration) -> bool {
    let end = Instant::now() + d;
    while Instant::now() < end {
        if shared.quit.load(Ordering::Relaxed) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    shared.quit.load(Ordering::Relaxed)
}

/// Connect/listen forever; run one connection at a time; survive disconnects and auth failures.
fn session_thread(connector: Connector, shared: Arc<Shared>, tx: mpsc::Sender<RenderCmd>, hwnd_raw: isize) {
    let mut listener: Option<std::net::TcpListener> = None;
    // Prefix shown in front of the waiting text (e.g. last error).
    let mut note: Option<String> = None;
    let mut ever_connected = false;
    // Listen mode: per-IP backoff after failed handshakes.
    let mut backoff = peers::Backoff::default();
    let pairing: Arc<GuiPairing> = Arc::new(GuiPairing { hwnd: hwnd_raw, cancel: Mutex::new(None) });
    loop {
        if shared.quit.load(Ordering::Relaxed) {
            return;
        }
        if shared.paused.load(Ordering::Relaxed) {
            // Tray "Disconnect": stop listening too, so the host can't reconnect until "Connect".
            listener = None;
            note = None;
            set_status(&shared, &tx, hwnd_raw, Some("Disconnected — use the tray icon to connect".into()));
            if sleep_or_quit(&shared, Duration::from_millis(200)) {
                return;
            }
            continue;
        }
        shared.abort_accept.store(false, Ordering::Relaxed);
        let host = shared.host_name.lock().unwrap().clone();
        let waiting = match &connector.target {
            Target::Listen(port) => {
                if ever_connected {
                    format!("Waiting for {host} to reconnect…")
                } else {
                    format!("Waiting for host on port {port}…")
                }
            }
            Target::Connect(addr) => {
                if ever_connected {
                    format!("Reconnecting to {host}…")
                } else {
                    format!("Connecting to {addr}…")
                }
            }
        };
        let text = match &note {
            Some(n) if n.ends_with('…') => n.clone(), // already a complete status line
            Some(n) => format!("{n} — {waiting}"),
            None => waiting,
        };
        set_status(&shared, &tx, hwnd_raw, Some(text));

        // Trust state for this attempt: the pinned host key (if paired) and our identity.
        let auth = Auth {
            identity: connector.identity.clone(),
            name: hello_name(&connector.hello),
            target: shared.pin_target.clone(),
            pinned: ui().store.lock().unwrap().config.pinned_key(&shared.pin_target),
            request_pairing: shared.repair.load(Ordering::Relaxed),
            pairing: pairing.clone(),
        };
        let res = match &connector.target {
            Target::Listen(port) => {
                if listener.is_none() {
                    match std::net::TcpListener::bind(("0.0.0.0", *port)) {
                        Ok(l) => {
                            eprintln!("listening on 0.0.0.0:{port}");
                            listener = Some(l);
                        }
                        Err(e) => {
                            note = Some(format!("Cannot listen on port {port}: {e}"));
                            if sleep_or_quit(&shared, Duration::from_secs(2)) {
                                return;
                            }
                            continue;
                        }
                    }
                }
                let hello = hello_for(&connector.hello, &shared);
                match accept_admitted(listener.as_ref().unwrap(), &auth, &hello, &shared, &mut backoff) {
                    Ok(Some((c, ip))) => {
                        // Trust on first use: pin the first host IP that authenticates.
                        let mut pinned = false;
                        ui().store.lock().unwrap().update(|c| pinned = peers::pin_first(&mut c.allowed_peers, ip));
                        if pinned {
                            eprintln!("pinned host {ip} (config allowed_peers); other IPs are now refused");
                            *shared.just_pinned.lock().unwrap() = Some(ip.to_string());
                        }
                        Ok(c)
                    }
                    Ok(None) if shared.quit.load(Ordering::Relaxed) => return,
                    Ok(None) => continue, // paused
                    Err(e) => Err(e),
                }
            }
            Target::Connect(addr) => Connection::connect(addr, &auth, &hello_for(&connector.hello, &shared)),
        };
        let conn = match res {
            Ok(c) => c,
            Err(e) => {
                eprintln!("connection attempt failed: {e}");
                if e.is_unknown_viewer() {
                    // The host no longer knows our key: ask to pair (same pinned host key) next time.
                    shared.repair.store(true, Ordering::Relaxed);
                }
                let label = match &connector.target {
                    Target::Listen(port) if !ever_connected => format!("the host on port {port}"),
                    Target::Connect(addr) if !ever_connected => addr.clone(),
                    _ => host.clone(),
                };
                let msg = e.user_message(&label);
                let rate_limited = matches!(e, ConnectError::Refused { status: crate::handshake::ST_RATE_LIMITED, .. });
                note = match &connector.target {
                    // Inbound peers are untrusted until their key checks out: keep listening.
                    Target::Listen(_) => match &e {
                        ConnectError::HostKeyChanged { .. } | ConnectError::Rejected(_) | ConnectError::PairingCancelled | ConnectError::PairingFailed(_) => {
                            Some(msg)
                        }
                        _ => Some(format!("A connection attempt failed ({}) — still waiting for {label}…", short_error(&msg))),
                    },
                    // While rate-limited, keep showing why we got there (e.g. "not paired yet").
                    Target::Connect(_) if rate_limited && note.is_some() => note,
                    Target::Connect(_) => Some(msg),
                };
                let retry = match (&connector.target, &e) {
                    (Target::Listen(_), _) => Duration::from_millis(200),
                    (Target::Connect(_), ConnectError::Refused { .. }) => Duration::from_secs(5),
                    (Target::Connect(_), _) => Duration::from_secs(2),
                };
                if sleep_or_quit(&shared, retry) {
                    return;
                }
                continue;
            }
        };
        if conn.paired {
            ui().store.lock().unwrap().pin_host(&shared.pin_target, &conn.host_key, &conn.host_name);
            shared.repair.store(false, Ordering::Relaxed);
            *shared.just_paired.lock().unwrap() = Some(crate::handshake::fingerprint(&conn.host_key));
        }
        ever_connected = true;
        let reason = run_connection(conn, &shared, &tx, hwnd_raw);
        match reason {
            None => return, // quitting
            Some(r) => {
                eprintln!("connection closed: {r}");
                if shared.reconnect.swap(false, Ordering::Relaxed) || shared.paused.load(Ordering::Relaxed) {
                    note = None; // on purpose: reconnect right away (or pause)
                    continue;
                }
                note = Some("Connection lost".into());
                if let Target::Connect(_) = connector.target {
                    if sleep_or_quit(&shared, Duration::from_secs(2)) {
                        return;
                    }
                }
            }
        }
    }
}

/// The viewer name sent in msg3 (= ClientHello's client_name).
fn hello_name(hello: &ClientMsg) -> String {
    match hello {
        ClientMsg::ClientHello { client_name, .. } => client_name.clone(),
        _ => "glide-viewer".into(),
    }
}

/// Listen mode: accept the next admitted peer (allowlist + backoff + pre-auth deadline, see
/// `peers::accept_admitted`). Ok(None) = interrupted by quit/pause.
fn accept_admitted(
    listener: &std::net::TcpListener,
    auth: &Auth,
    hello: &ClientMsg,
    shared: &Shared,
    backoff: &mut peers::Backoff,
) -> Result<Option<(Connection, std::net::IpAddr)>, ConnectError> {
    let allowed = || ui().store.lock().unwrap().config.allowed_peers.clone();
    peers::accept_admitted(listener, auth, hello, &shared.abort_accept, &allowed, backoff, crate::net::HANDSHAKE_TIMEOUT)
}

/// ClientHello with the current monitor's view size / refresh (the window may have moved).
fn hello_for(template: &ClientMsg, shared: &Shared) -> ClientMsg {
    match template {
        ClientMsg::ClientHello { version, codec_caps, client_name, .. } => {
            let (w, h, fps) = *shared.view.lock().unwrap();
            *shared.sent_view.lock().unwrap() = (w, h);
            // Clipboard sync is advertised only while the user switch is on (menu → Clipboard sync).
            let codec_caps = if clipboard::is_active() { *codec_caps } else { *codec_caps & !protocol::CAP_CLIPBOARD };
            ClientMsg::ClientHello {
                version: *version,
                codec_caps,
                view_w: w,
                view_h: h,
                // The mode may have been changed with Ctrl+Alt+Shift+M since startup.
                mode: shared.mode.load(Ordering::Relaxed),
                max_fps: fps,
                client_name: client_name.clone(),
            }
        }
        other => other.clone(),
    }
}

fn short_error(e: &str) -> String {
    let e = e.split(" (os error").next().unwrap_or(e);
    if e.chars().count() > 80 { e.chars().take(80).collect::<String>() + "…" } else { e.to_string() }
}

/// Run one authenticated connection until it closes. Returns the close reason, or None on quit.
fn run_connection(mut conn: Connection, shared: &Arc<Shared>, tx: &mpsc::Sender<RenderCmd>, hwnd_raw: isize) -> Option<String> {
    let cfg = conn.config;
    eprintln!(
        "connected to {} ({}x{} {} {}, scale {})",
        conn.host_name,
        cfg.width,
        cfg.height,
        cfg.codec.name(),
        cfg.chroma_name(),
        cfg.scale
    );
    *shared.host_name.lock().unwrap() = conn.host_name.clone();
    *shared.config.lock().unwrap() = cfg;
    *shared.display_info.lock().unwrap() = None; // until this host sends DisplayInfo
    *shared.displays.lock().unwrap() = None; // until this host sends DisplayList (§3.5)
    shared.display_restore_done.store(false, Ordering::Relaxed);
    *shared.display_restoring.lock().unwrap() = None;
    *shared.clock.lock().unwrap() = Some(conn.clock.clone());
    {
        // Fresh cursor state for the new host session.
        let mut c = shared.cursor.lock().unwrap();
        c.shapes.clear();
        c.current = None;
        c.visible = true;
    }
    // New configuration: resets the base decoder and canvas (sharp layer follows via SharpLayerConfig).
    let _ = tx.send(RenderCmd::Config(cfg));
    shared.latency.lock().unwrap().reset();

    let (ended_tx, ended_rx) = mpsc::channel::<String>();
    {
        let shared = shared.clone();
        let tx = tx.clone();
        let sender = conn.sender.clone();
        conn.spawn_receiver(move |ev| match ev {
            NetEvent::Msg(HostMsg::VideoFrame { frame_id, flags, rects, data, .. }) => {
                shared.latency.lock().unwrap().on_recv(frame_id, flags, now_us());
                shared.stats.bytes.fetch_add(data.len() as u64, Ordering::Relaxed);
                let _ = tx.send(RenderCmd::Frame {
                    frame_id,
                    data,
                    keyframe: flags & FRAME_FLAG_KEYFRAME != 0,
                    sharp: flags & FRAME_FLAG_SHARP != 0,
                    rects,
                });
            }
            NetEvent::Msg(HostMsg::SharpLayerConfig(c)) => {
                let _ = tx.send(RenderCmd::SharpConfig(c));
            }
            NetEvent::Msg(HostMsg::FrameTiming(ft)) => shared.latency.lock().unwrap().on_timing(ft, now_us()),
            NetEvent::Msg(HostMsg::VideoConfig(c)) | NetEvent::Msg(HostMsg::ServerHello { config: c, .. }) => {
                *shared.config.lock().unwrap() = c;
                let _ = tx.send(RenderCmd::Config(c));
            }
            NetEvent::Msg(HostMsg::CursorShape { shape_id, w, h, hot_x, hot_y, bgra }) => {
                let mut c = shared.cursor.lock().unwrap();
                c.shapes.insert(
                    shape_id,
                    CursorImage { w: w as u32, h: h as u32, hot_x: hot_x as u32, hot_y: hot_y as u32, bgra },
                );
                c.current = Some(shape_id);
                drop(c);
                post(hwnd_raw, WM_APP_CURSOR);
            }
            NetEvent::Msg(HostMsg::CursorShapeRef { shape_id }) => {
                let mut c = shared.cursor.lock().unwrap();
                if c.shapes.contains_key(&shape_id) {
                    c.current = Some(shape_id);
                }
                drop(c);
                post(hwnd_raw, WM_APP_CURSOR);
            }
            NetEvent::Msg(HostMsg::AudioConfig(c)) => {
                if let Some(a) = &shared.audio {
                    a.on_config(&c);
                }
            }
            NetEvent::Msg(HostMsg::AudioFrame { seq, capture_time_us, data }) => {
                if let Some(a) = &shared.audio {
                    a.on_frame(seq, capture_time_us, &data);
                }
            }
            NetEvent::Msg(HostMsg::CursorPos { visible, .. }) => {
                let mut c = shared.cursor.lock().unwrap();
                if c.visible != visible {
                    c.visible = visible;
                    drop(c);
                    post(hwnd_raw, WM_APP_CURSOR);
                }
            }
            NetEvent::Msg(HostMsg::ClipboardCaps { formats, max_bytes }) => clipboard::enable(sender.clone(), formats, max_bytes),
            NetEvent::Msg(HostMsg::DisplayInfo { preference, mode_w, mode_h, hidpi }) => {
                let d = menu_model::DisplayInfo { preference, mode_w, mode_h, hidpi };
                eprintln!("mac display: {} ({})", d.describe(), menu_model::display_pref_name(preference));
                *shared.display_info.lock().unwrap() = Some(d);
            }
            NetEvent::Msg(HostMsg::DisplayList { streamed, selected, displays }) => {
                let st = {
                    let mut g = shared.displays.lock().unwrap();
                    let st = g.get_or_insert_with(DisplayState::default);
                    st.apply_list(streamed, selected, displays);
                    st.clone()
                };
                eprintln!(
                    "mac displays: {} (streaming {}{})",
                    st.displays.iter().map(|d| format!("{} {}", d.id, displays::label(d))).collect::<Vec<_>>().join("; "),
                    st.streamed,
                    if st.selected != 0 { ", selected" } else { "" }
                );
                // First list of this connection: re-select the display chosen last time (by identity;
                // ids change across reconnects). Nothing is sent if it isn't connected to the Mac now.
                if !shared.display_restore_done.swap(true, Ordering::Relaxed) {
                    let remembered = ui().store.lock().unwrap().config.last_display.get(&shared.pin_target).cloned();
                    match displays::restore_choice(remembered.as_ref(), &st) {
                        Some(id) => {
                            eprintln!("display: re-selecting remembered “{}” (now id {id})", st.name(id));
                            *shared.display_restoring.lock().unwrap() = Some(id);
                            let _ = sender.send(&ClientMsg::SelectDisplay { display_id: id });
                        }
                        None if remembered.is_some() && st.selected == 0 => {
                            eprintln!("display: remembered “{}” isn't connected to the Mac; showing the default", remembered.unwrap().name)
                        }
                        None => {}
                    }
                }
            }
            NetEvent::Msg(HostMsg::DisplayChanged { display_id, reason, requested }) => {
                let st = shared.displays.lock().unwrap().clone().unwrap_or_default();
                let restoring = {
                    let mut r = shared.display_restoring.lock().unwrap();
                    let was = *r == Some(requested) && reason == protocol::DISPLAY_REASON_SELECTED;
                    if *r == Some(requested) {
                        *r = None;
                    }
                    was
                };
                // Only the viewer's own choices are remembered (not hot-plug fallbacks or the Mac menu).
                if let Some(m) = displays::remember_after(&st, display_id, reason, requested) {
                    let key = shared.pin_target.clone();
                    ui().store.lock().unwrap().update(|c| match m {
                        Some(i) => {
                            c.last_display.insert(key, i);
                        }
                        None => {
                            c.last_display.remove(&key);
                        }
                    });
                }
                let t = displays::changed_toast(&st, display_id, reason, requested, restoring);
                eprintln!("display: {t} (id {display_id}, reason {reason}, requested {requested})");
                let _ = tx.send(RenderCmd::Toast(t));
            }
            NetEvent::Msg(HostMsg::Clipboard(c)) => clipboard::incoming(c),
            NetEvent::Msg(HostMsg::File(m)) => files::incoming(m),
            NetEvent::Msg(_) => {}
            NetEvent::Closed(reason) => {
                let _ = ended_tx.send(reason);
            }
        });
    }
    let _pinger = conn.spawn_pinger(crate::net::PING_INTERVAL);
    // Per-frame host timestamps for the latency breakdown (§3.4); older hosts ignore this.
    let _ = conn.sender.send(&ClientMsg::LatencyEnable { flags: 1 });
    if let Some(a) = &shared.audio {
        a.on_connected(conn.clock.clone());
        if a.muted() {
            // Mute persists across reconnects; audio is on by default host-side.
            let _ = conn.sender.send(&ClientMsg::AudioEnable { enabled: false });
        }
    }
    *shared.sender.lock().unwrap() = Some(conn.sender.clone());
    files::connected(conn.sender.clone());
    set_status(shared, tx, hwnd_raw, None);
    post(hwnd_raw, WM_APP_CONNECTED);

    let reason = loop {
        match ended_rx.recv_timeout(Duration::from_millis(100)) {
            Ok(r) => break Some(r),
            Err(mpsc::RecvTimeoutError::Disconnected) => break Some("receiver ended".into()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if shared.quit.load(Ordering::Relaxed) {
                    break None;
                }
            }
        }
    };
    *shared.sender.lock().unwrap() = None;
    *shared.clock.lock().unwrap() = None;
    clipboard::disable();
    files::disconnected();
    if let Some(a) = &shared.audio {
        a.on_disconnected();
    }
    conn.stop();
    post(hwnd_raw, WM_APP_DISCONNECTED);
    reason
}

pub fn run(connector: Connector, opts: Options) -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let initial_status = match &connector.target {
        Target::Listen(port) => format!("Waiting for host on port {port}…"),
        Target::Connect(addr) => format!("Connecting to {addr}…"),
    };
    let shared = Arc::new(Shared {
        host_name: Mutex::new(opts.host_label.clone()),
        mode: AtomicU8::new(opts.mode as u8),
        has444: opts.has444,
        repair: AtomicBool::new(false),
        reconnect: AtomicBool::new(false),
        paused: AtomicBool::new(false),
        abort_accept: AtomicBool::new(false),
        listening: matches!(connector.target, Target::Listen(_)),
        just_pinned: Mutex::new(None),
        just_paired: Mutex::new(None),
        pin_target: connector.pin_target.clone(),
        config: Mutex::new(VideoConfig { width: 0, height: 0, codec: protocol::Codec::Hevc, chroma: 0, color: 0, scale: 1.0 }),
        sender: Mutex::new(None),
        clock: Mutex::new(None),
        status: Mutex::new(Some(initial_status.clone())),
        quit: AtomicBool::new(false),
        view: Mutex::new(match &connector.hello {
            ClientMsg::ClientHello { view_w, view_h, max_fps, .. } => (*view_w, *view_h, *max_fps),
            _ => (0, 0, 60),
        }),
        sent_view: Mutex::new((0, 0)),
        view_override: std::env::var("GLIDE_VIEW").ok().and_then(|v| {
            let (w, h) = v.split_once('x')?;
            Some((w.parse().ok()?, h.parse().ok()?))
        }),
        decoder_desc: Mutex::new(String::new()),
        cursor: Mutex::new(CursorState { visible: true, ..Default::default() }),
        stats: Stats::default(),
        hwnd: AtomicIsize::new(0),
        audio: opts.audio.then(Audio::start),
        latency: Mutex::new(Tracker::new(true)),
        latency_test: AtomicBool::new(false),
        present_info: Mutex::new("null".into()),
        clock_info: Mutex::new("null".into()),
        display_info: Mutex::new(None),
        displays: Mutex::new(None),
        display_restore_done: AtomicBool::new(false),
        display_restoring: Mutex::new(None),
    });
    let (render_tx, render_rx) = mpsc::channel::<RenderCmd>();
    let latency_test = opts.latency_test || std::env::var("GLIDE_LATENCY_TEST").is_ok_and(|v| v == "1");
    // The latency test lives in the HUD.
    let hud_on = opts.store.config.hud || latency_test;
    let opts_audio_muted = opts.audio_muted;
    let opts_bar_pinned = opts.store.config.bar_pinned;
    let opts_clipboard = opts.clipboard;
    let restore = {
        let ms = placement::monitors();
        config::choose_placement(&opts.store.config, &ms, placement::cursor_monitor_index(&ms))
    };
    let _ = UI.set(UiCtx {
        ctrl_as_cmd: opts.ctrl_as_cmd,
        render_tx: Mutex::new(render_tx.clone()),
        shared: shared.clone(),
        store: Mutex::new(opts.store),
    });
    if latency_test {
        set_latency_test(true);
    }
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.hud_on = hud_on;
        // GLIDE_TEST_ACTIONS=hud,mode,... (test hook): run these actions one per tick.
        s.test_actions = std::env::var("GLIDE_TEST_ACTIONS")
            .map(|v| v.split(',').filter_map(TestStep::parse).rev().collect())
            .unwrap_or_default();
    });

    // --- window (shown immediately, before any connection)
    let hwnd = unsafe {
        let hinst = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class = w!("GlideViewer");
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS,
            lpfnWndProc: Some(wndproc),
            hInstance: HINSTANCE(hinst.0),
            hCursor: HCURSOR::default(), // we set it per WM_SETCURSOR
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            lpszClassName: class,
            hIcon: prompt::app_icon(GetSystemMetrics(SM_CXICON))
                .or_else(|| LoadIconW(None, IDI_APPLICATION).ok())
                .unwrap_or_default(),
            hIconSm: prompt::app_icon(GetSystemMetrics(SM_CXSMICON)).unwrap_or_default(),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 {
            return Err("RegisterClassExW failed".into());
        }
        // Video size is unknown until the host connects: start at 16:9 within the work area of
        // the monitor under the cursor (the same monitor ClientHello reports).
        let mon = super::cursor_monitor();
        let (cw, ch) = match mon {
            Some(m) => {
                let (aw, ah) = ((m.work.right - m.work.left) as f32 * 0.8, (m.work.bottom - m.work.top) as f32 * 0.8);
                let (_, _, w, h) = letterbox(aw as u32, ah as u32, 16, 9);
                (w.max(320), h.max(180))
            }
            None => initial_client_size(2560, 1440),
        };
        let style = WS_OVERLAPPEDWINDOW;
        let mut rc = RECT { left: 0, top: 0, right: cw, bottom: ch };
        let dpi = GetDpiForSystem();
        let _ = AdjustWindowRectExForDpi(&mut rc, style, false, WINDOW_EX_STYLE(0), dpi);
        let title: Vec<u16> = format!("Glide — {initial_status}").encode_utf16().chain(std::iter::once(0)).collect();
        // Restore the remembered placement (last monitor) if any, else centered on the cursor monitor.
        let (x, y, w, h) = match &restore {
            Some(p) => (p.rect.l, p.rect.t, p.rect.w(), p.rect.h()),
            None => (
                mon.map_or(CW_USEDEFAULT, |m| m.work.left + ((m.work.right - m.work.left) - (rc.right - rc.left)) / 2),
                mon.map_or(CW_USEDEFAULT, |m| m.work.top + ((m.work.bottom - m.work.top) - (rc.bottom - rc.top)) / 2),
                rc.right - rc.left,
                rc.bottom - rc.top,
            ),
        };
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(title.as_ptr()),
            style,
            x,
            y,
            w,
            h,
            None,
            None,
            Some(HINSTANCE(hinst.0)),
            None,
        )
        .map_err(|e| format!("CreateWindowExW: {e}"))?
    };
    let hwnd_raw = hwnd.0 as isize;
    shared.hwnd.store(hwnd_raw, Ordering::Relaxed);
    track_normal_rect(hwnd);
    let show = match &restore {
        Some(p) if p.fullscreen => {
            toggle_fullscreen(hwnd);
            if p.maximized {
                // Leaving fullscreen later returns to a maximized window.
                STATE.with(|s| {
                    if let Some(f) = s.borrow_mut().fullscreen_saved.as_mut() {
                        f.1.showCmd = SW_SHOWMAXIMIZED.0 as u32;
                    }
                });
            }
            SW_SHOW
        }
        Some(p) if p.maximized => SW_SHOWMAXIMIZED,
        _ => SW_SHOW,
    };
    if let Some(p) = &restore {
        eprintln!("restored window on monitor {} (fullscreen={}, maximized={})", p.monitor, p.fullscreen, p.maximized);
    }
    if opts_audio_muted {
        if let Some(a) = &shared.audio {
            a.set_muted(true); // run_connection tells the host (AudioEnable false) on connect
        }
    }
    menu::init_dark_mode();
    menu::refresh_system_menu(hwnd, &menu_model::system_items(&menu_state()));
    {
        let tx = render_tx.clone();
        cbar::init(hwnd, opts_bar_pinned, "Glide — not connected", Box::new(move |t| {
            let _ = tx.send(RenderCmd::Bar(t));
        }));
    }
    check_view(hwnd); // view = the monitor the window actually opened on (before the first hello)
    clipboard::set_active(hwnd, opts_clipboard);
    clipboard::init(hwnd);
    if let Some(m) = files::init(hwnd, &ui().store.lock().unwrap().config.clone()) {
        toast(m);
    }

    // --- render thread
    let init = client_size(hwnd);
    let rt = {
        let shared = shared.clone();
        std::thread::Builder::new()
            .name("glide-render".into())
            .spawn(move || render_thread(hwnd_raw, render_rx, shared, init))
            .map_err(|e| e.to_string())?
    };

    // --- session thread (connect/listen, reconnect forever)
    {
        let shared = shared.clone();
        let tx = render_tx.clone();
        std::thread::Builder::new()
            .name("glide-session".into())
            .spawn(move || session_thread(connector, shared, tx, hwnd_raw))
            .map_err(|e| e.to_string())?;
    }

    unsafe {
        let _ = ShowWindow(hwnd, show);
        let _ = UpdateWindow(hwnd);
        SetTimer(Some(hwnd), TITLE_TIMER, 500, None);
        if STATE.with(|s| !s.borrow().test_actions.is_empty()) {
            let ms = std::env::var("GLIDE_TEST_ACTIONS_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(1500);
            SetTimer(Some(hwnd), TEST_ACTION_TIMER, ms, None);
        }
    }
    if std::env::var("GLIDE_NO_TRAY").as_deref() != Ok("1") {
        let t = tray::Tray::new(hwnd, WM_APP_TRAY);
        t.add();
        STATE.with(|s| s.borrow_mut().tray = Some(t));
    }
    update_title(hwnd);
    // Test hook: GLIDE_EXIT_AFTER=SECONDS closes the window automatically (smoke tests).
    let exit_after = std::env::var("GLIDE_EXIT_AFTER").ok().and_then(|v| v.parse::<f64>().ok());
    if let Some(secs) = exit_after {
        unsafe {
            SetTimer(Some(hwnd), EXIT_TIMER, (secs * 1000.0) as u32, None);
        }
    }
    super::console::detach_if_own_console();

    // --- message loop
    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    // User closed the window: stop everything (the session thread notices `quit`).
    shared.quit.store(true, Ordering::Relaxed);
    shared.abort_accept.store(true, Ordering::Relaxed);
    if let Some(s) = shared.sender.lock().unwrap().take() {
        let _ = s.send(&ClientMsg::ReleaseAll);
        s.shutdown();
    }
    let _ = render_tx.send(RenderCmd::Quit);
    if let Some(a) = &shared.audio {
        a.shutdown();
    }
    let _ = rt.join();
    if shared.latency_test.load(Ordering::Relaxed) {
        if let Some(p) = write_latency_report() {
            eprintln!("latency report written to {p}");
        }
    }
    if exit_after.is_some() {
        let st = &shared.stats;
        eprintln!(
            "viewer exit: decoded={} sharp={} rect_frames={} presented={} bytes={} decode_errors={} decoder={:?} status={:?} last_title={:?} mode={} hud={:?}",
            st.decoded.load(Ordering::Relaxed),
            st.sharp.load(Ordering::Relaxed),
            st.rect_frames.load(Ordering::Relaxed),
            st.presented.load(Ordering::Relaxed),
            st.bytes.load(Ordering::Relaxed),
            st.decode_errors.load(Ordering::Relaxed),
            shared.decoder_desc.lock().unwrap(),
            shared.status.lock().unwrap(),
            STATE.with(|s| s.borrow().last_title.clone()),
            Mode::from_u8(shared.mode.load(Ordering::Relaxed)).name(),
            STATE.with(|s| s.borrow().last_hud.clone())
        );
    }
    Ok(())
}
