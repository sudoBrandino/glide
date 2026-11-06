//! Audio output (docs/PROTOCOL.md §3.2): WASAPI shared-mode, event-driven render of the
//! jitter buffer in `crate::audio`, on a dedicated MMCSS ("Pro Audio") thread.
//!
//! - The stream format is the wire format (48 kHz stereo float); `AUTOCONVERTPCM` lets Windows
//!   resample/remix to whatever the device's mix format is.
//! - Shared-mode device buffer (Windows gives ~22 ms at a 10 ms engine period), refilled on every
//!   engine event but only up to `GLIDE_AUDIO_FILL_MS` (default 16 ms) of queued audio: the
//!   engine needs one period per pass, so this keeps ~6 ms of slack for thread wake-up lateness
//!   while not parking an extra ~6 ms of latency in the device. `GLIDE_AUDIO_LOWLAT=1` tries
//!   IAudioClient3 at the engine's minimum period.
//! - The default render device is re-checked every second; a switch (or a device error such as
//!   `AUDCLNT_E_DEVICE_INVALIDATED`) reopens on the new default device.
//! - The device is only open while the host is sending audio and the viewer isn't muted.

use crate::audio::{JitterBuffer, JitterParams};
use crate::net::ClockSync;
use crate::protocol::{AudioConfig, AUDIO_CODEC_PCM_S16};
use crate::util::{json_opt, json_str, now_us, percentile};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::core::{w, Interface, PWSTR};
use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Media::Audio::*;
use windows::Win32::Media::Multimedia::KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
use windows::Win32::System::Com::StructuredStorage::{PropVariantClear, PropVariantToStringAlloc};
use windows::Win32::System::Com::*;
use windows::Win32::System::Threading::{AvRevertMmThreadCharacteristics, AvSetMmThreadCharacteristicsW, CreateEventW, WaitForSingleObject};

const WAVE_FORMAT_EXTENSIBLE: u16 = 0xFFFE;

/// What the title bar shows and `--audio-selftest` reports.
#[derive(Default, Clone)]
pub struct AudioStatus {
    pub device: Option<String>,
    pub error: Option<String>,
    /// Estimated host-capture → speaker latency (needs ping clock sync).
    pub e2e_ms: Option<f64>,
    /// Audio queued in the device buffer (+ the engine's reported stream latency).
    pub device_ms: f64,
    pub jitter_ms: f64,
    pub target_ms: f64,
    pub underruns: u64,
    pub lost: u64,
    pub trims: u64,
    pub resampling: bool,
    pub opens: u64,
    /// Engine events where the device buffer had already run dry (audible glitch).
    pub device_starved: u64,
}

#[derive(Default)]
struct RunStats {
    events: u64,
    event_gaps_ms: Vec<f64>,
    padding_ms: Vec<f64>,
}

struct Inner {
    jb: Mutex<JitterBuffer>,
    /// Some((rate, channels)) while the host is sending PCM.
    format: Mutex<Option<(u32, u16)>>,
    generation: AtomicU64,
    muted: AtomicBool,
    quit: AtomicBool,
    clock: Mutex<Option<Arc<Mutex<ClockSync>>>>,
    status: Mutex<AudioStatus>,
    run_stats: Mutex<RunStats>,
    buffer_ms: f64,
    fill_ms: f64,
}

impl Inner {
    fn active(&self) -> Option<(u32, u16)> {
        if self.muted.load(Ordering::Relaxed) {
            return None;
        }
        *self.format.lock().unwrap()
    }
}

/// Handle shared by the UI / network threads. Cheap to clone.
#[derive(Clone)]
pub struct Audio {
    inner: Arc<Inner>,
}

impl Audio {
    /// Spawns the audio thread (idle until an AudioConfig arrives).
    pub fn start() -> Audio {
        let buffer_ms = std::env::var("GLIDE_AUDIO_BUFFER_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(20.0).clamp(3.0, 200.0);
        let fill_ms = std::env::var("GLIDE_AUDIO_FILL_MS").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(16.0).clamp(2.0, 500.0);
        let mut params = JitterParams::default();
        if let Some(t) = std::env::var("GLIDE_AUDIO_TARGET_MS").ok().and_then(|v| v.parse::<f64>().ok()) {
            params.target_ms = t.clamp(5.0, 500.0);
            params.max_target_ms = params.max_target_ms.max(params.target_ms);
        }
        let inner = Arc::new(Inner {
            jb: Mutex::new(JitterBuffer::new(48_000, 2, params)),
            format: Mutex::new(None),
            generation: AtomicU64::new(0),
            muted: AtomicBool::new(false),
            quit: AtomicBool::new(false),
            clock: Mutex::new(None),
            status: Mutex::new(AudioStatus::default()),
            run_stats: Mutex::new(RunStats::default()),
            buffer_ms,
            fill_ms,
        });
        let i = inner.clone();
        let _ = std::thread::Builder::new().name("glide-audio".into()).spawn(move || audio_thread(i));
        Audio { inner }
    }

    pub fn on_connected(&self, clock: Arc<Mutex<ClockSync>>) {
        *self.inner.clock.lock().unwrap() = Some(clock);
    }

    pub fn on_disconnected(&self) {
        *self.inner.format.lock().unwrap() = None;
        *self.inner.clock.lock().unwrap() = None;
        self.inner.generation.fetch_add(1, Ordering::Relaxed);
    }

    /// AudioConfig: a new stream (flush), or codec 0 = no audio from this host.
    pub fn on_config(&self, c: &AudioConfig) {
        let ok = c.codec == AUDIO_CODEC_PCM_S16 && (1..=8).contains(&c.channels) && (8_000..=192_000).contains(&c.sample_rate);
        if !ok && c.codec != 0 {
            eprintln!("audio: unsupported AudioConfig {c:?}; ignoring audio");
        }
        let fmt = ok.then_some((c.sample_rate, c.channels as u16));
        eprintln!("audio: stream {}", match fmt {
            Some((r, ch)) => format!("PCM {r} Hz {ch} ch, {} samples/frame", c.frame_samples),
            None => "off".into(),
        });
        if let Some((r, ch)) = fmt {
            self.inner.jb.lock().unwrap().reset(r, ch as usize);
        }
        *self.inner.format.lock().unwrap() = fmt;
        self.inner.generation.fetch_add(1, Ordering::Relaxed);
    }

    pub fn on_frame(&self, seq: u32, capture_time_us: u64, data: &[u8]) {
        if self.inner.active().is_some() {
            self.inner.jb.lock().unwrap().push(seq, capture_time_us, data);
        }
    }

    pub fn muted(&self) -> bool {
        self.inner.muted.load(Ordering::Relaxed)
    }

    /// Returns the new muted state. The caller tells the host (AudioEnable).
    pub fn set_muted(&self, m: bool) -> bool {
        self.inner.muted.store(m, Ordering::Relaxed);
        if m {
            // Unmuting starts fresh: the host re-sends AudioConfig, which resets the buffer.
            let mut jb = self.inner.jb.lock().unwrap();
            let (r, c) = (jb.rate(), jb.channels());
            jb.reset(r, c);
        }
        m
    }

    pub fn status(&self) -> AudioStatus {
        self.inner.status.lock().unwrap().clone()
    }

    /// Short title-bar text, e.g. "audio 58 ms", "audio muted", or "" when there is no stream.
    pub fn status_text(&self) -> String {
        if self.muted() {
            return "audio muted".into();
        }
        if self.inner.format.lock().unwrap().is_none() {
            return String::new();
        }
        let s = self.status();
        if let Some(e) = &s.error {
            return format!("audio error: {e}");
        }
        let mut t = match s.e2e_ms {
            Some(ms) => format!("audio {ms:.0} ms"),
            None => format!("audio buf {:.0}+{:.0} ms", s.jitter_ms, s.device_ms),
        };
        if s.underruns > 0 {
            t.push_str(&format!(" ({} underruns)", s.underruns));
        }
        t
    }

    pub fn shutdown(&self) {
        self.inner.quit.store(true, Ordering::Relaxed);
    }
}

// ------------------------------------------------------------------ device

fn pwstr_to_string(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    let s = unsafe { p.to_string() }.unwrap_or_default();
    unsafe { CoTaskMemFree(Some(p.0 as *const _)) };
    s
}

fn enumerator() -> windows::core::Result<IMMDeviceEnumerator> {
    unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
}

fn device_id(d: &IMMDevice) -> String {
    unsafe { d.GetId() }.map(pwstr_to_string).unwrap_or_default()
}

fn device_name(d: &IMMDevice) -> String {
    unsafe {
        let Ok(store) = d.OpenPropertyStore(STGM_READ) else { return "?".into() };
        let Ok(mut pv) = store.GetValue(&PKEY_Device_FriendlyName) else { return "?".into() };
        let s = PropVariantToStringAlloc(&pv).map(pwstr_to_string).unwrap_or_else(|_| "?".into());
        let _ = PropVariantClear(&mut pv);
        s
    }
}

fn default_device(e: &IMMDeviceEnumerator) -> windows::core::Result<IMMDevice> {
    unsafe { e.GetDefaultAudioEndpoint(eRender, eConsole) }
}

fn channel_mask(ch: u16) -> u32 {
    match ch {
        1 => 0x4,   // front center
        2 => 0x3,   // front left | right
        4 => 0x33,  // quad
        6 => 0x3F,  // 5.1
        8 => 0x63F, // 7.1
        n => (1u32 << n) - 1,
    }
}

fn float_format(rate: u32, ch: u16) -> WAVEFORMATEXTENSIBLE {
    WAVEFORMATEXTENSIBLE {
        Format: WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_EXTENSIBLE,
            nChannels: ch,
            nSamplesPerSec: rate,
            nAvgBytesPerSec: rate * ch as u32 * 4,
            nBlockAlign: ch * 4,
            wBitsPerSample: 32,
            cbSize: 22,
        },
        Samples: WAVEFORMATEXTENSIBLE_0 { wValidBitsPerSample: 32 },
        dwChannelMask: channel_mask(ch),
        SubFormat: KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
    }
}

struct Device {
    client: IAudioClient,
    render: IAudioRenderClient,
    event: HANDLE,
    id: String,
    name: String,
    buffer_frames: u32,
    rate: u32,
    channels: u16,
    latency_ms: f64,
    default_period_ms: f64,
    min_period_ms: f64,
}

impl Drop for Device {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
            let _ = CloseHandle(self.event);
        }
    }
}

impl Device {
    fn open(e: &IMMDeviceEnumerator, rate: u32, ch: u16, buffer_ms: f64) -> windows::core::Result<Device> {
        unsafe {
            let dev = default_device(e)?;
            let fmt = float_format(rate, ch);
            // Opt-in (GLIDE_AUDIO_LOWLAT=1): IAudioClient3 at the engine's minimum period (e.g. 3 ms
            // instead of 10 ms). Only works when our format is the device mix format (no
            // AUTOCONVERTPCM); otherwise fall back to the normal shared-mode stream.
            let mut low = None;
            if std::env::var("GLIDE_AUDIO_LOWLAT").as_deref() == Ok("1") {
                let c3: IAudioClient3 = dev.Activate(CLSCTX_ALL, None)?;
                let (mut def, mut fund, mut min, mut max) = (0u32, 0u32, 0u32, 0u32);
                let r = c3
                    .GetSharedModeEnginePeriod(&fmt.Format, &mut def, &mut fund, &mut min, &mut max)
                    .and_then(|_| c3.InitializeSharedAudioStream(AUDCLNT_STREAMFLAGS_EVENTCALLBACK, min, &fmt.Format, None));
                match r {
                    Ok(()) => {
                        eprintln!("audio: low-latency shared stream, period {min} frames (default {def}, fundamental {fund})");
                        low = Some(c3.cast::<IAudioClient>()?);
                    }
                    Err(e) => eprintln!("audio: low-latency stream unavailable ({e}); using the standard shared stream"),
                }
            }
            let client = match low {
                Some(c) => c,
                None => {
                    let client: IAudioClient = dev.Activate(CLSCTX_ALL, None)?;
                    let flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
                    let hns = (buffer_ms * 10_000.0) as i64;
                    client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, hns, 0, &fmt.Format, None)?;
                    client
                }
            };
            let event = CreateEventW(None, false, false, None)?;
            client.SetEventHandle(event)?;
            let buffer_frames = client.GetBufferSize()?;
            let render: IAudioRenderClient = client.GetService()?;
            let (mut def, mut min) = (0i64, 0i64);
            let _ = client.GetDevicePeriod(Some(&mut def), Some(&mut min));
            let latency_ms = client.GetStreamLatency().unwrap_or(0) as f64 / 10_000.0;
            Ok(Device {
                client,
                render,
                event,
                id: device_id(&dev),
                name: device_name(&dev),
                buffer_frames,
                rate,
                channels: ch,
                latency_ms,
                default_period_ms: def as f64 / 10_000.0,
                min_period_ms: min as f64 / 10_000.0,
            })
        }
    }

    fn buffer_ms(&self) -> f64 {
        self.buffer_frames as f64 * 1000.0 / self.rate as f64
    }
}

enum Stop {
    Inactive,
    FormatChanged,
    DeviceChanged,
    Error(String),
}

/// Event loop: refill the device buffer from the jitter buffer on every engine event.
fn render_loop(inner: &Inner, e: &IMMDeviceEnumerator, dev: &Device, gen: u64) -> Stop {
    let ch = dev.channels as usize;
    let mut buf: Vec<f32> = Vec::with_capacity(dev.buffer_frames as usize * ch);
    // Start from the steady-state fill level of silence; the loop tops it up on each event.
    let pre = ((inner.fill_ms * dev.rate as f64 / 1000.0) as u32).min(dev.buffer_frames);
    let prefill = unsafe { dev.render.GetBuffer(pre).and_then(|_| dev.render.ReleaseBuffer(pre, AUDCLNT_BUFFERFLAGS_SILENT.0 as u32)) };
    if let Err(err) = prefill {
        return Stop::Error(format!("prefill: {err}"));
    }
    if let Err(err) = unsafe { dev.client.Start() } {
        return Stop::Error(format!("Start: {err}"));
    }
    let mut last_check = Instant::now();
    let mut last_event: Option<u64> = None;
    let mut e2e_ema: Option<f64> = None;
    // Fill cap: at least one engine period (+1 ms), at most the whole buffer.
    let period = (dev.default_period_ms.max(1.0) * dev.rate as f64 / 1000.0) as u32;
    let fill_cap = ((inner.fill_ms * dev.rate as f64 / 1000.0) as u32).max(period + dev.rate / 1000).min(dev.buffer_frames);
    let mut started = false;
    loop {
        let woke = unsafe { WaitForSingleObject(dev.event, 100) } == WAIT_OBJECT_0;
        if inner.quit.load(Ordering::Relaxed) || inner.active().is_none() {
            return Stop::Inactive;
        }
        if inner.generation.load(Ordering::Relaxed) != gen && inner.active() != Some((dev.rate, dev.channels)) {
            return Stop::FormatChanged;
        }
        if last_check.elapsed() >= Duration::from_secs(1) {
            last_check = Instant::now();
            match default_device(e) {
                Ok(d) if device_id(&d) != dev.id => return Stop::DeviceChanged,
                Ok(_) => {}
                Err(err) => return Stop::Error(format!("default device: {err}")),
            }
        }
        if woke {
            let now = now_us();
            let mut rs = inner.run_stats.lock().unwrap();
            rs.events += 1;
            if let Some(l) = last_event {
                if rs.event_gaps_ms.len() < 100_000 {
                    rs.event_gaps_ms.push((now - l) as f64 / 1000.0);
                }
            }
            last_event = Some(now);
        }
        let padding = match unsafe { dev.client.GetCurrentPadding() } {
            Ok(p) => p,
            Err(err) => return Stop::Error(format!("GetCurrentPadding: {err}")),
        };
        if woke && started && padding == 0 {
            inner.status.lock().unwrap().device_starved += 1;
        }
        started = true;
        let avail = fill_cap.saturating_sub(padding) as usize;
        if avail == 0 {
            continue;
        }
        buf.clear();
        buf.resize(avail * ch, 0.0);
        let (playing, ts) = {
            let mut jb = inner.jb.lock().unwrap();
            let ts = jb.next_play_ts_us();
            jb.pull(&mut buf);
            let mut st = inner.status.lock().unwrap();
            st.jitter_ms = jb.level_ms();
            st.target_ms = jb.target_ms();
            st.underruns = jb.stats.underruns;
            st.lost = jb.stats.lost_packets;
            st.trims = jb.stats.trims;
            st.resampling = jb.ratio() != 1.0;
            (jb.is_playing(), ts)
        };
        let queued_ms = padding as f64 * 1000.0 / dev.rate as f64;
        {
            let mut rs = inner.run_stats.lock().unwrap();
            if rs.padding_ms.len() < 100_000 {
                rs.padding_ms.push(queued_ms);
            }
        }
        // Capture → speaker estimate for the first frame just pulled: it plays after the
        // `padding` frames already queued plus the engine's stream latency.
        if let (true, Some(ts)) = (playing, ts) {
            let host_to_client = inner.clock.lock().unwrap().as_ref().and_then(|c| c.lock().unwrap().host_to_client_us(ts));
            if let Some(cap) = host_to_client {
                let e2e = (now_us() as i64 - cap) as f64 / 1000.0 + queued_ms + dev.latency_ms;
                if (0.0..2000.0).contains(&e2e) {
                    e2e_ema = Some(e2e_ema.map_or(e2e, |v| v + 0.05 * (e2e - v)));
                }
            }
        }
        {
            let mut st = inner.status.lock().unwrap();
            st.device_ms = queued_ms + dev.latency_ms;
            st.e2e_ms = e2e_ema;
        }
        unsafe {
            let p = match dev.render.GetBuffer(avail as u32) {
                Ok(p) => p,
                Err(err) => return Stop::Error(format!("GetBuffer: {err}")),
            };
            std::ptr::copy_nonoverlapping(buf.as_ptr(), p as *mut f32, avail * ch);
            if let Err(err) = dev.render.ReleaseBuffer(avail as u32, 0) {
                return Stop::Error(format!("ReleaseBuffer: {err}"));
            }
        }
    }
}

fn sleep_while(inner: &Inner, d: Duration, gen: u64) {
    let end = Instant::now() + d;
    while Instant::now() < end && !inner.quit.load(Ordering::Relaxed) && inner.generation.load(Ordering::Relaxed) == gen {
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn audio_thread(inner: Arc<Inner>) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let mut task = 0u32;
    let mmcss = unsafe { AvSetMmThreadCharacteristicsW(w!("Pro Audio"), &mut task) }.ok();
    let mut enumr: Option<IMMDeviceEnumerator> = None;
    while !inner.quit.load(Ordering::Relaxed) {
        let Some((rate, ch)) = inner.active() else {
            std::thread::sleep(Duration::from_millis(20));
            continue;
        };
        let gen = inner.generation.load(Ordering::Relaxed);
        if enumr.is_none() {
            match enumerator() {
                Ok(e) => enumr = Some(e),
                Err(err) => {
                    inner.status.lock().unwrap().error = Some(format!("no audio device enumerator: {err}"));
                    sleep_while(&inner, Duration::from_secs(2), gen);
                    continue;
                }
            }
        }
        let e = enumr.as_ref().unwrap();
        let dev = match Device::open(e, rate, ch, inner.buffer_ms) {
            Ok(d) => d,
            Err(err) => {
                let msg = format!("cannot open output device: {err}");
                let mut st = inner.status.lock().unwrap();
                if st.error.as_deref() != Some(&msg) {
                    eprintln!("audio: {msg}");
                }
                st.error = Some(msg);
                drop(st);
                sleep_while(&inner, Duration::from_secs(1), gen);
                continue;
            }
        };
        eprintln!(
            "audio: playing on '{}' ({} Hz {} ch float, buffer {} frames = {:.1} ms, period {:.1}/{:.1} ms, stream latency {:.1} ms)",
            dev.name,
            dev.rate,
            dev.channels,
            dev.buffer_frames,
            dev.buffer_ms(),
            dev.default_period_ms,
            dev.min_period_ms,
            dev.latency_ms
        );
        {
            let mut st = inner.status.lock().unwrap();
            st.device = Some(dev.name.clone());
            st.error = None;
            st.opens += 1;
        }
        let why = render_loop(&inner, e, &dev, gen);
        drop(dev);
        match why {
            Stop::Inactive => {}
            Stop::FormatChanged => eprintln!("audio: stream format changed; reopening"),
            Stop::DeviceChanged => eprintln!("audio: default output device changed; switching"),
            Stop::Error(msg) => {
                eprintln!("audio: {msg}; reopening");
                inner.status.lock().unwrap().error = Some(msg);
                enumr = None;
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
    if let Some(h) = mmcss {
        unsafe {
            let _ = AvRevertMmThreadCharacteristics(h);
        }
    }
}

// ------------------------------------------------------------------ headless self-test

/// `--audio-selftest [SECONDS]`: enumerate output devices, open the default one exactly as the
/// viewer does, and run the real render path for a few seconds fed with **digital silence**
/// (all-zero PCM through the jitter buffer) — nothing audible. Prints one JSON object.
pub fn selftest_json(seconds: f64) -> String {
    let mut errors: Vec<String> = Vec::new();
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let mut devices = Vec::new();
    let mut default_json = "null".to_string();
    let mut mix_json = "null".to_string();
    match enumerator() {
        Err(e) => errors.push(format!("enumerator: {e}")),
        Ok(e) => unsafe {
            if let Ok(col) = e.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) {
                for i in 0..col.GetCount().unwrap_or(0) {
                    if let Ok(d) = col.Item(i) {
                        devices.push(json_str(&device_name(&d)));
                    }
                }
            }
            match default_device(&e) {
                Err(err) => errors.push(format!("default render device: {err}")),
                Ok(d) => {
                    default_json = format!("{{\"name\":{},\"id\":{}}}", json_str(&device_name(&d)), json_str(&device_id(&d)));
                    match d.Activate::<IAudioClient>(CLSCTX_ALL, None).and_then(|c| c.GetMixFormat()) {
                        Ok(p) => {
                            let f = *p;
                            let (rate, ch, bits, tag) = (f.nSamplesPerSec, f.nChannels, f.wBitsPerSample, f.wFormatTag);
                            mix_json = format!("{{\"rate\":{rate},\"channels\":{ch},\"bits\":{bits},\"tag\":{tag}}}");
                            CoTaskMemFree(Some(p as *const _));
                        }
                        Err(err) => errors.push(format!("mix format: {err}")),
                    }
                }
            }
        },
    }

    // Real path: Audio handle + thread, fed zeros at 10 ms cadence like the network would.
    let audio = Audio::start();
    audio.on_config(&AudioConfig { codec: AUDIO_CODEC_PCM_S16, sample_rate: 48_000, channels: 2, frame_samples: 480 });
    let silence = vec![0u8; 480 * 2 * 2];
    let t0 = Instant::now();
    let mut seq = 0u32;
    while t0.elapsed().as_secs_f64() < seconds {
        audio.on_frame(seq, seq as u64 * 10_000, &silence);
        seq += 1;
        let next = Duration::from_millis(10 * seq as u64);
        if let Some(d) = next.checked_sub(t0.elapsed()) {
            std::thread::sleep(d);
        }
    }
    let st = audio.status();
    let (frames_out, level) = {
        let jb = audio.inner.jb.lock().unwrap();
        (jb.stats.frames_out, jb.level_ms())
    };
    let rs = std::mem::take(&mut *audio.inner.run_stats.lock().unwrap());
    audio.shutdown();
    std::thread::sleep(Duration::from_millis(150));
    if let Some(e) = &st.error {
        errors.push(e.clone());
    }
    let gaps = &rs.event_gaps_ms;
    let pad = &rs.padding_ms;
    format!(
        "{{\"devices\":[{}],\"default_device\":{},\"mix_format\":{},\"opened\":{},\"seconds\":{seconds},\"events\":{},\"event_gap_ms\":{{\"p50\":{},\"p99\":{},\"max\":{}}},\"device_queue_ms\":{{\"min\":{},\"p50\":{},\"max\":{}}},\"device_ms_with_latency\":{},\"fill_ms\":{},\"device_starved\":{},\"jitter_level_ms\":{},\"target_ms\":{},\"frames_played\":{},\"underruns\":{},\"errors\":[{}]}}",
        devices.join(","),
        default_json,
        mix_json,
        st.opens,
        rs.events,
        json_opt(percentile(gaps, 50.0)),
        json_opt(percentile(gaps, 99.0)),
        json_opt(gaps.iter().cloned().fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))),
        json_opt(pad.iter().cloned().fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.min(v))))),
        json_opt(percentile(pad, 50.0)),
        json_opt(pad.iter().cloned().fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))),
        json_opt(Some(st.device_ms)),
        json_opt(Some(audio.inner.fill_ms)),
        st.device_starved,
        json_opt(Some(level)),
        json_opt(Some(st.target_ms)),
        frames_out,
        st.underruns,
        errors.iter().map(|e| json_str(e)).collect::<Vec<_>>().join(",")
    )
}
