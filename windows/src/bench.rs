//! Headless benchmark: connect, receive + decode for N seconds, print one JSON line.
//! The decoder is abstracted so the network path can also be exercised on macOS.

use crate::net::{Connection, NetEvent};
use crate::protocol::{ClientMsg, HostMsg, VideoConfig, FRAME_FLAG_KEYFRAME, FRAME_FLAG_REFRESH, FRAME_FLAG_SHARP};
use crate::util::{json_opt, json_str, now_us, percentile};
use std::sync::mpsc;
use std::time::{Duration, Instant};

pub trait BenchDecoder {
    /// (Re)create the decoder for a new configuration.
    fn configure(&mut self, cfg: &VideoConfig) -> Result<(), String>;
    /// Decode one access unit; returns number of frames output (0 if the decoder is still
    /// buffering). Implementations should wait for GPU completion so timing is honest.
    fn decode(&mut self, data: &[u8], keyframe: bool) -> Result<u32, String>;
    /// Short JSON object describing the decoder (name, hw, output format...).
    fn describe_json(&self) -> String;
}

/// Decoder that does nothing (non-Windows builds): measures network only.
pub struct NullDecoder;
impl BenchDecoder for NullDecoder {
    fn configure(&mut self, _: &VideoConfig) -> Result<(), String> {
        Ok(())
    }
    fn decode(&mut self, _: &[u8], _: bool) -> Result<u32, String> {
        Ok(1)
    }
    fn describe_json(&self) -> String {
        "{\"name\":\"null (no decode on this platform)\",\"hw\":false}".into()
    }
}

pub fn run(mut conn: Connection, seconds: f64, dec: &mut dyn BenchDecoder, sharp: &mut dyn BenchDecoder) -> String {
    let (tx, rx) = mpsc::channel::<(NetEvent, u64)>();
    let _rx_thread = conn.spawn_receiver(move |ev| {
        let _ = tx.send((ev, now_us()));
    });
    let _ping = conn.spawn_pinger(crate::net::PING_INTERVAL);
    let sender = conn.sender.clone();
    // Ask for per-frame host timestamps (§3.4); hosts without it ignore this.
    let _ = sender.send(&ClientMsg::LatencyEnable { flags: 1 });
    let mut lat = crate::latency::Tracker::new(false);
    lat.keep_all = true;
    let mut last_tick = Instant::now();
    let mut cfg = conn.config;
    let mut sharp_cfg: Option<VideoConfig> = None;
    let mut errors: Vec<String> = Vec::new();
    if let Err(e) = dec.configure(&cfg) {
        errors.push(format!("configure: {e}"));
    }

    let start = Instant::now();
    let deadline = start + Duration::from_secs_f64(seconds);
    let mut frames_rx = 0u64;
    let mut frames_out = 0u64;
    let mut keyframes = 0u64;
    let mut bytes = 0u64;
    let mut sharp_bytes = 0u64;
    let mut decode_ms: Vec<f64> = Vec::new(); // base layer
    let mut sharp_decode_ms: Vec<f64> = Vec::new();
    let mut queue_ms: Vec<f64> = Vec::new(); // receive -> decode start
    let mut e2e_ms: Vec<f64> = Vec::new(); // host capture -> decoded (clock-sync estimate), base non-refresh only
    let mut configs = 0u32;
    let mut sharp_configs = 0u32;
    let mut cursor_shapes = 0u32;
    let mut base_frames = 0u64;
    let mut sharp_frames = 0u64;
    let mut sharp_rx = 0u64;
    let mut refresh_frames = 0u64;
    let mut rect_frames = 0u64;
    let mut rect_total = 0u64;
    let mut rect_area_frac: Vec<f64> = Vec::new();
    let mut first_frame_at: Option<Instant> = None;
    let mut last_frame_at: Option<Instant> = None;
    let mut need_key = true;
    let mut skipped_until_key = 0u64;
    let mut closed: Option<String> = None;
    // Audio (§3.2): arrival statistics only (nothing is played).
    let mut audio_cfg: Option<crate::protocol::AudioConfig> = None;
    let mut audio_frames = 0u64;
    let mut audio_samples = 0u64;
    let mut audio_lost = 0u64;
    let mut audio_next_seq: Option<u32> = None;
    let mut audio_delay_ms: Vec<f64> = Vec::new(); // first-sample capture -> arrival
    let mut audio_last_rx: Option<u64> = None;
    let mut audio_max_gap_ms = 0f64;

    while Instant::now() < deadline {
        let left = deadline.saturating_duration_since(Instant::now());
        if last_tick.elapsed() > Duration::from_millis(200) {
            last_tick = Instant::now();
            let clock = conn.clock.lock().unwrap();
            lat.tick(now_us(), clock.offset_us.is_some().then_some(&*clock));
        }
        let (ev, rx_us) = match rx.recv_timeout(left.min(Duration::from_millis(200))) {
            Ok(x) => x,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        match ev {
            NetEvent::Closed(reason) => {
                closed = Some(reason);
                break;
            }
            NetEvent::Msg(HostMsg::VideoConfig(c)) | NetEvent::Msg(HostMsg::ServerHello { config: c, .. }) => {
                configs += 1;
                cfg = c;
                need_key = true;
                if let Err(e) = dec.configure(&cfg) {
                    errors.push(format!("configure: {e}"));
                }
            }
            NetEvent::Msg(HostMsg::SharpLayerConfig(c)) => {
                sharp_configs += 1;
                sharp_cfg = Some(c);
                if let Err(e) = sharp.configure(&c) {
                    errors.push(format!("sharp configure: {e}"));
                }
            }
            NetEvent::Msg(HostMsg::FrameTiming(ft)) => lat.on_timing(ft, rx_us),
            NetEvent::Msg(HostMsg::VideoFrame { frame_id, capture_time_us, flags, rects, data }) if flags & FRAME_FLAG_SHARP != 0 => {
                lat.on_recv(frame_id, flags, rx_us);
                frames_rx += 1;
                sharp_rx += 1;
                bytes += data.len() as u64;
                sharp_bytes += data.len() as u64;
                if sharp_cfg.is_none() {
                    // Tolerate a missing SharpLayerConfig: same geometry as the base, HEVC 4:4:4.
                    let c = VideoConfig { codec: crate::protocol::Codec::Hevc, chroma: 1, ..cfg };
                    errors.push("sharp frame before SharpLayerConfig".into());
                    sharp_cfg = Some(c);
                    let _ = sharp.configure(&c);
                }
                let msg = "sharp frame with rects (spec says full frame; applied as full)".to_string();
                if rects.is_some() && !errors.contains(&msg) {
                    errors.push(msg);
                }
                let t0 = now_us();
                match sharp.decode(&data, true) {
                    Ok(n) => {
                        let t1 = now_us();
                        sharp_decode_ms.push((t1 - t0) as f64 / 1000.0);
                        if n > 0 {
                            lat.on_decode(frame_id, t0, t1);
                        }
                        sharp_frames += n as u64;
                        frames_out += n as u64;
                    }
                    Err(e) => {
                        if errors.len() < 20 {
                            errors.push(format!("sharp decode: {e}"));
                        }
                        let _ = sharp.configure(sharp_cfg.as_ref().unwrap());
                    }
                }
                let _ = capture_time_us;
            }
            NetEvent::Msg(HostMsg::VideoFrame { frame_id, capture_time_us, flags, rects, data }) => {
                lat.on_recv(frame_id, flags, rx_us);
                frames_rx += 1;
                bytes += data.len() as u64;
                let key = flags & FRAME_FLAG_KEYFRAME != 0;
                let refresh = flags & FRAME_FLAG_REFRESH != 0;
                if key {
                    keyframes += 1;
                }
                if refresh {
                    refresh_frames += 1;
                }
                if let Some(rs) = &rects {
                    rect_frames += 1;
                    rect_total += rs.len() as u64;
                    let area: u64 = rs
                        .iter()
                        .filter_map(|r| r.clamped(cfg.width as u32, cfg.height as u32))
                        .map(|(_, _, w, h)| w as u64 * h as u64)
                        .sum();
                    rect_area_frac.push(area as f64 / (cfg.width as f64 * cfg.height as f64).max(1.0));
                }
                if need_key && !key {
                    skipped_until_key += 1;
                    continue;
                }
                need_key = false;
                let t0 = now_us();
                queue_ms.push((t0 - rx_us) as f64 / 1000.0);
                match dec.decode(&data, key) {
                    Ok(n) => {
                        let t1 = now_us();
                        decode_ms.push((t1 - t0) as f64 / 1000.0);
                        frames_out += n as u64;
                        base_frames += n as u64;
                        if n > 0 {
                            lat.on_decode(frame_id, t0, t1);
                            let now = Instant::now();
                            first_frame_at.get_or_insert(now);
                            last_frame_at = Some(now);
                            if !refresh {
                                if let Some(cap) = conn.clock.lock().unwrap().host_to_client_us(capture_time_us) {
                                    e2e_ms.push((t1 as i64 - cap) as f64 / 1000.0);
                                }
                            }
                        }
                    }
                    Err(e) => {
                        if errors.len() < 20 {
                            errors.push(format!("decode: {e}"));
                        }
                        need_key = true;
                        let _ = sender.send(&ClientMsg::RequestKeyframe);
                        let _ = dec.configure(&cfg);
                    }
                }
            }
            NetEvent::Msg(HostMsg::CursorShape { .. }) => cursor_shapes += 1,
            NetEvent::Msg(HostMsg::AudioConfig(c)) => {
                audio_cfg = Some(c);
                audio_next_seq = None;
            }
            NetEvent::Msg(HostMsg::AudioFrame { seq, capture_time_us, data }) => {
                audio_frames += 1;
                if let Some(c) = audio_cfg.filter(|c| c.channels > 0) {
                    audio_samples += data.len() as u64 / (2 * c.channels as u64);
                }
                if let Some(e) = audio_next_seq {
                    let d = seq.wrapping_sub(e);
                    if d != 0 && d < 1 << 31 {
                        audio_lost += d as u64;
                    }
                }
                audio_next_seq = Some(seq.wrapping_add(1));
                if let Some(cap) = conn.clock.lock().unwrap().host_to_client_us(capture_time_us) {
                    audio_delay_ms.push((rx_us as i64 - cap) as f64 / 1000.0);
                }
                if let Some(l) = audio_last_rx {
                    audio_max_gap_ms = audio_max_gap_ms.max((rx_us - l) as f64 / 1000.0);
                }
                audio_last_rx = Some(rx_us);
            }
            NetEvent::Msg(_) => {}
        }
    }
    let elapsed = start.elapsed().as_secs_f64();
    conn.stop();
    if let Some(c) = &closed {
        errors.push(format!("connection closed: {c}"));
    }
    errors.dedup();

    let clock = conn.clock.lock().unwrap();
    lat.tick(now_us(), clock.offset_us.is_some().then_some(&*clock));
    let latency = format!(
        "{{\"host_timing\":{},\"breakdown\":{},\"clock\":{{\"min_rtt_ms\":{},\"drift_ppm\":{:.2},\"window_samples\":{}}}}}",
        lat.host_timing_seen,
        lat.report_json(),
        json_opt(clock.min_rtt_us().map(|u| u as f64 / 1000.0)),
        clock.drift_ppm(),
        clock.window_samples()
    );
    let fps_window = match (first_frame_at, last_frame_at) {
        (Some(a), Some(b)) if base_frames > 1 && b > a => Some((base_frames - 1) as f64 / (b - a).as_secs_f64()),
        _ => None,
    };
    let notes = format!(
        "e2e = host capture_time -> base-layer frame decoded on client (GPU-complete), excluding refresh and sharp-layer frames, \
         using a sliding-window min-RTT Ping/Pong clock-offset estimate (error bound ~ +/- min_rtt/2 = {:.2} ms); excludes display scan-out. \
         latency.breakdown: per-stage distributions (docs/LATENCY.md) when the host sends FrameTiming (latency.host_timing).",
        clock.min_rtt_us().map_or(f64::NAN, |u| u as f64 / 2000.0)
    );
    let errs: Vec<String> = errors.iter().map(|e| json_str(e)).collect();
    let audio = match audio_cfg {
        None => "null".to_string(),
        Some(c) => format!(
            "{{\"codec\":{},\"rate\":{},\"channels\":{},\"frames\":{},\"seconds_of_audio\":{:.2},\"lost_frames\":{},\"capture_to_arrival_ms\":{{\"p50\":{},\"p95\":{},\"max\":{}}},\"max_arrival_gap_ms\":{:.1}}}",
            c.codec,
            c.sample_rate,
            c.channels,
            audio_frames,
            audio_samples as f64 / c.sample_rate.max(1) as f64,
            audio_lost,
            json_opt(percentile(&audio_delay_ms, 50.0)),
            json_opt(percentile(&audio_delay_ms, 95.0)),
            json_opt(audio_delay_ms.iter().cloned().reduce(f64::max)),
            audio_max_gap_ms
        ),
    };
    let layers = format!(
        concat!(
            "{{\"base_frames\":{},\"sharp_frames\":{},\"sharp_received\":{},\"sharp_configs\":{},\"sharp_mbytes\":{:.3},",
            "\"refresh_frames\":{},\"rect_frames\":{},\"avg_rects\":{},\"rect_area_pct_p50\":{},",
            "\"sharp_decode_ms\":{{\"p50\":{},\"max\":{}}},\"sharp_decoder\":{}}}"
        ),
        base_frames,
        sharp_frames,
        sharp_rx,
        sharp_configs,
        sharp_bytes as f64 / 1e6,
        refresh_frames,
        rect_frames,
        json_opt((rect_frames > 0).then(|| rect_total as f64 / rect_frames as f64)),
        json_opt(percentile(&rect_area_frac, 50.0).map(|f| f * 100.0)),
        json_opt(percentile(&sharp_decode_ms, 50.0)),
        json_opt(sharp_decode_ms.iter().cloned().reduce(f64::max)),
        if sharp_cfg.is_some() { sharp.describe_json() } else { "null".into() },
    );
    format!(
        concat!(
            "{{\"host\":{},\"seconds\":{:.2},\"video\":{{\"width\":{},\"height\":{},\"codec\":{},\"chroma\":{},\"scale\":{}}},",
            "\"decoder\":{},\"frames\":{},\"frames_received\":{},\"skipped_waiting_keyframe\":{},\"fps\":{:.2},\"fps_while_streaming\":{},",
            "\"keyframes\":{},\"configs\":{},\"cursor_shapes\":{},\"bytes\":{},\"mbps\":{:.3},\"layers\":{},",
            "\"decode_ms\":{{\"p50\":{},\"p95\":{},\"max\":{}}},\"recv_to_decode_start_ms_p50\":{},",
            "\"rtt_ms\":{{\"p50\":{},\"min\":{},\"samples\":{}}},\"e2e_capture_to_decoded_ms\":{{\"p50\":{},\"p95\":{},\"samples\":{}}},",
            "\"audio\":{},\"latency\":{},\"est_latency_notes\":{},\"errors\":[{}]}}"
        ),
        json_str(&conn.host_name),
        elapsed,
        cfg.width,
        cfg.height,
        json_str(cfg.codec.name()),
        json_str(cfg.chroma_name()),
        cfg.scale,
        dec.describe_json(),
        frames_out,
        frames_rx,
        skipped_until_key,
        frames_out as f64 / elapsed,
        json_opt(fps_window),
        keyframes,
        configs,
        cursor_shapes,
        bytes,
        bytes as f64 * 8.0 / elapsed / 1e6,
        layers,
        json_opt(percentile(&decode_ms, 50.0)),
        json_opt(percentile(&decode_ms, 95.0)),
        json_opt(decode_ms.iter().cloned().reduce(f64::max)),
        json_opt(percentile(&queue_ms, 50.0)),
        json_opt(percentile(&clock.rtts_ms, 50.0)),
        json_opt(clock.rtts_ms.iter().cloned().reduce(f64::min)),
        clock.rtts_ms.len(),
        json_opt(percentile(&e2e_ms, 50.0)),
        json_opt(percentile(&e2e_ms, 95.0)),
        e2e_ms.len(),
        audio,
        latency,
        json_str(&notes),
        errs.join(",")
    )
}
