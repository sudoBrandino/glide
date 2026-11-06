//! Stats overlay (HUD) model: rate computation from cumulative counters and the text lines.
//! Platform independent; the Windows renderer rasterizes the lines.

use crate::protocol::Mode;

/// Cumulative counters sampled at one instant.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Counters {
    pub t_us: u64,
    pub decoded: u64,
    pub presented: u64,
    pub bytes: u64,
    pub decode_us: u64,
}

/// Rates between two samples.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rates {
    pub fps: f64,
    pub mbps: f64,
    /// Mean decode (+ canvas copy) time per decoded frame, ms. None if nothing was decoded.
    pub decode_ms: Option<f64>,
}

pub fn rates(prev: &Counters, now: &Counters) -> Rates {
    let dt = (now.t_us.saturating_sub(prev.t_us) as f64 / 1e6).max(0.001);
    let dec = now.decoded.saturating_sub(prev.decoded);
    Rates {
        fps: now.presented.saturating_sub(prev.presented) as f64 / dt,
        mbps: now.bytes.saturating_sub(prev.bytes) as f64 * 8.0 / dt / 1e6,
        decode_ms: (dec > 0).then(|| now.decode_us.saturating_sub(prev.decode_us) as f64 / dec as f64 / 1000.0),
    }
}

/// Audio state for the HUD (None in `HudInfo` = audio disabled with --no-audio / config).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct AudioHud {
    pub muted: bool,
    /// The host is sending audio (an AudioConfig arrived).
    pub streaming: bool,
    /// Estimated host capture → speaker latency (needs ping clock sync).
    pub e2e_ms: Option<f64>,
    /// Jitter buffer + device queue, ms (shown when e2e isn't known yet).
    pub buffer_ms: f64,
    pub underruns: u64,
    pub error: Option<String>,
}

pub fn audio_line(a: &AudioHud) -> String {
    if a.muted {
        return "audio muted (Ctrl+Alt+Shift+A)".into();
    }
    if let Some(e) = &a.error {
        return format!("audio error: {e}");
    }
    if !a.streaming {
        return "audio: no stream".into();
    }
    let mut t = match a.e2e_ms {
        Some(ms) => format!("audio {ms:.0} ms"),
        None => format!("audio buf {:.0} ms", a.buffer_ms),
    };
    t.push_str(&format!("   underruns {}", a.underruns));
    t
}

/// Everything the HUD shows.
#[derive(Debug, Clone, Default)]
pub struct HudInfo {
    pub host_name: String,
    /// Some while not connected (status line).
    pub status: Option<String>,
    pub video: (u16, u16),
    pub codec: String,
    pub chroma: String,
    pub decoder: String,
    pub rates: Rates,
    pub rtt_ms: Option<f64>,
    pub mode: Option<Mode>,
    /// The most recent canvas update came from the 4:4:4 sharp layer.
    pub showing_sharp: bool,
    pub sharp_frames: u64,
    pub rect_frames: u64,
    pub decode_errors: u64,
    pub view: (u16, u16),
    pub keyboard_captured: bool,
    pub audio: Option<AudioHud>,
}

/// The HUD text, one entry per line.
pub fn lines(i: &HudInfo) -> Vec<String> {
    let mut v = Vec::with_capacity(8);
    v.push(format!("Glide · {}", i.host_name));
    if let Some(s) = &i.status {
        v.push(s.clone());
        v.push(format!("view {}x{}", i.view.0, i.view.1));
        return v;
    }
    let dec = i.rates.decode_ms.map_or("–".to_string(), |d| format!("{d:.1} ms"));
    let rtt = i.rtt_ms.map_or("–".to_string(), |r| format!("{r:.1} ms"));
    v.push(format!("{:>3.0} fps   decode {dec}   rtt {rtt}", i.rates.fps));
    v.push(format!("{:.1} Mbps   {}x{} {} {}", i.rates.mbps, i.video.0, i.video.1, i.codec, i.chroma));
    let layer = match i.mode {
        Some(Mode::Hybrid) => {
            if i.showing_sharp {
                "4:4:4"
            } else {
                "4:2:0"
            }
        }
        Some(Mode::Sharp) => "4:4:4",
        _ => "4:2:0",
    };
    let mode = i.mode.map_or("?", |m| m.name());
    v.push(format!("mode {mode} [{layer}]   sharp {}   rects {}", i.sharp_frames, i.rect_frames));
    let mut last = format!("view {}x{}   {}", i.view.0, i.view.1, i.decoder);
    if i.decode_errors > 0 {
        last.push_str(&format!("   {} decode errors", i.decode_errors));
    }
    v.push(last);
    if let Some(a) = &i.audio {
        v.push(audio_line(a));
    }
    if !i.keyboard_captured {
        v.push("keyboard released (Ctrl+Alt+Shift+K)".into());
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_text() {
        let mut a = AudioHud::default();
        assert_eq!(audio_line(&a), "audio: no stream");
        a.streaming = true;
        a.buffer_ms = 46.2;
        assert_eq!(audio_line(&a), "audio buf 46 ms   underruns 0");
        a.e2e_ms = Some(58.4);
        a.underruns = 2;
        assert_eq!(audio_line(&a), "audio 58 ms   underruns 2");
        a.error = Some("device lost".into());
        assert_eq!(audio_line(&a), "audio error: device lost");
        a.muted = true;
        assert!(audio_line(&a).starts_with("audio muted"));
    }

    #[test]
    fn rate_math() {
        let a = Counters { t_us: 1_000_000, decoded: 10, presented: 10, bytes: 0, decode_us: 0 };
        let b = Counters { t_us: 1_500_000, decoded: 40, presented: 40, bytes: 1_250_000, decode_us: 60_000 };
        let r = rates(&a, &b);
        assert!((r.fps - 60.0).abs() < 1e-9);
        assert!((r.mbps - 20.0).abs() < 1e-9);
        assert!((r.decode_ms.unwrap() - 2.0).abs() < 1e-9);
        let idle = rates(&b, &Counters { t_us: 2_000_000, ..b });
        assert_eq!(idle.fps, 0.0);
        assert_eq!(idle.decode_ms, None);
        // counters reset (new session) never underflow
        let r = rates(&b, &Counters { t_us: 2_000_000, ..Default::default() });
        assert_eq!(r.fps, 0.0);
    }

    #[test]
    fn hud_text() {
        let mut i = HudInfo {
            host_name: "Example-Mac".into(),
            video: (3072, 1728),
            codec: "HEVC".into(),
            chroma: "4:2:0".into(),
            decoder: "hw NV12 + AYUV".into(),
            rates: Rates { fps: 59.6, mbps: 12.34, decode_ms: Some(1.84) },
            rtt_ms: Some(2.5),
            mode: Some(Mode::Hybrid),
            showing_sharp: true,
            sharp_frames: 12,
            rect_frames: 340,
            view: (3072, 1728),
            keyboard_captured: true,
            ..Default::default()
        };
        let l = lines(&i);
        assert_eq!(l[0], "Glide · Example-Mac");
        assert_eq!(l[1], " 60 fps   decode 1.8 ms   rtt 2.5 ms");
        assert_eq!(l[2], "12.3 Mbps   3072x1728 HEVC 4:2:0");
        assert_eq!(l[3], "mode hybrid [4:4:4]   sharp 12   rects 340");
        assert_eq!(l[4], "view 3072x1728   hw NV12 + AYUV");
        assert_eq!(l.len(), 5);
        i.showing_sharp = false;
        i.decode_errors = 2;
        i.keyboard_captured = false;
        i.rtt_ms = None;
        i.rates.decode_ms = None;
        let l = lines(&i);
        assert!(l[1].contains("decode –") && l[1].contains("rtt –"));
        assert!(l[3].contains("[4:2:0]"));
        assert!(l[4].ends_with("2 decode errors"));
        assert!(l[5].contains("keyboard released"));
        i.keyboard_captured = true;
        i.audio = Some(AudioHud { streaming: true, e2e_ms: Some(41.6), underruns: 3, ..Default::default() });
        assert_eq!(lines(&i).last().unwrap(), "audio 42 ms   underruns 3");
        i.status = Some("Waiting for host on port 7420…".into());
        assert_eq!(lines(&i), vec!["Glide · Example-Mac", "Waiting for host on port 7420…", "view 3072x1728"]);
    }
}
