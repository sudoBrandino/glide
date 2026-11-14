//! Seeded mutation fuzzing of every decoder that sees bytes from the host (or from any peer before
//! authentication), run by plain `cargo test` on every platform. The Swift counterpart is
//! `mac/Sources/glide-selftest/FuzzTests.swift`.
//!
//! Corpus: the records, handshake flights and payloads in `docs/test-vectors*.json`, the messages
//! and paths in `docs/file-transfer-vectors.json`, the reference encodings of PROTOCOL.md §3–6
//! and the bundled video clips. Each input is mutated (bit flips, boundary integers, special
//! floats, truncation, insertion, splicing) and fed to the decoders. The property is "returns Ok
//! or Err", never a panic; decoded messages must re-encode to something that decodes again, and
//! sanitized file names must be safe.
//!
//! Deterministic: `GLIDE_FUZZ_SEED` and `GLIDE_FUZZ_ITERS` reproduce or extend a run. A panic
//! prints the seed, the target and the input (hex) before it unwinds.

use crate::annexb;
use crate::audio::{JitterBuffer, JitterParams};
use crate::clipboard;
use crate::crypto::Opener;
use crate::files;
use crate::handshake::{self, HostHandshake, HostInfo, ViewerHandshake, ViewerInfo};
use crate::protocol::*;
use crate::util::{hex, unhex};
use x25519_dalek::StaticSecret;

/// SplitMix64: tiny, seedable, identical to the Swift harness.
pub(crate) struct Rng(u64);

impl Rng {
    pub(crate) fn new(seed: u64) -> Rng {
        Rng(seed)
    }
    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    pub(crate) fn below(&mut self, n: usize) -> usize {
        if n <= 1 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
    fn byte(&mut self) -> u8 {
        self.next() as u8
    }
}

/// Integers at the edges of every field width (lengths, counts, sizes, offsets).
const BOUNDARY_INTS: [u64; 18] = [
    0,
    1,
    2,
    0x7F,
    0x80,
    0xFF,
    0x100,
    0x7FFF,
    0x8000,
    0xFFFF,
    0x1_0000,
    0x7FFF_FFFF,
    0x8000_0000,
    0xFFFF_FFFF,
    0x1_0000_0000,
    0x7FFF_FFFF_FFFF_FFFF,
    0x8000_0000_0000_0000,
    u64::MAX,
];
/// f32 specials for coordinates, scales and deltas.
const BOUNDARY_FLOATS: [f32; 12] = [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, f32::MAX, f32::MIN, f32::MIN_POSITIVE, 1e-45, 1e30, -1e30, 0.0, -0.0, 1.0];

pub(crate) fn mutate(input: &[u8], rng: &mut Rng, corpus: &[Vec<u8>]) -> Vec<u8> {
    let mut b = input.to_vec();
    for _ in 0..=rng.below(4) {
        match rng.below(10) {
            0 if !b.is_empty() => {
                let i = rng.below(b.len());
                b[i] ^= 1 << rng.below(8);
            }
            1 if !b.is_empty() => {
                let i = rng.below(b.len());
                b[i] = rng.byte();
            }
            2 if !b.is_empty() => {
                let width = [1, 2, 4, 8][rng.below(4)];
                let v = BOUNDARY_INTS[rng.below(BOUNDARY_INTS.len())];
                let at = rng.below(b.len());
                for k in 0..width {
                    if let Some(x) = b.get_mut(at + k) {
                        *x = (v >> (8 * k)) as u8;
                    }
                }
            }
            3 if !b.is_empty() => {
                let bits = BOUNDARY_FLOATS[rng.below(BOUNDARY_FLOATS.len())].to_bits();
                let at = rng.below(b.len());
                for k in 0..4 {
                    if let Some(x) = b.get_mut(at + k) {
                        *x = (bits >> (8 * k)) as u8;
                    }
                }
            }
            4 => {
                let n = rng.below(b.len() + 1);
                b.truncate(n);
            }
            5 => {
                let at = rng.below(b.len() + 1);
                let n = 1 + rng.below(16);
                let ins: Vec<u8> = (0..n).map(|_| rng.byte()).collect();
                b.splice(at..at, ins);
            }
            6 if !b.is_empty() => {
                let at = rng.below(b.len());
                let n = 1 + rng.below(16.min(b.len() - at));
                b.drain(at..at + n);
            }
            7 if !b.is_empty() => {
                let at = rng.below(b.len());
                let n = 1 + rng.below(32.min(b.len() - at));
                let dup = b[at..at + n].to_vec();
                let to = rng.below(b.len() + 1);
                b.splice(to..to, dup);
            }
            8 if !corpus.is_empty() => {
                let o = &corpus[rng.below(corpus.len())];
                let keep = rng.below(b.len() + 1);
                let tail = rng.below(o.len() + 1);
                b.truncate(keep);
                b.extend_from_slice(&o[o.len() - tail..]);
            }
            9 if !b.is_empty() => b[0] = rng.byte(),
            _ => b.push(rng.byte()),
        }
    }
    b
}

pub(crate) fn seed() -> u64 {
    std::env::var("GLIDE_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0x6C69_6465_2D66_757A)
}

pub(crate) fn iters() -> usize {
    std::env::var("GLIDE_FUZZ_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(3000)
}

/// Runs `f`; on a panic, reports the target, seed and input before failing the test.
fn guard<T>(target: &str, input: &[u8], f: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(e) => {
            let why = e.downcast_ref::<String>().cloned().or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
            let shown = &input[..input.len().min(256)];
            let more = if input.len() > shown.len() { format!("… ({} bytes)", input.len()) } else { String::new() };
            panic!("fuzz: {target} panicked ({why}) on input {}{more} (GLIDE_FUZZ_SEED={})", hex(shown), seed());
        }
    }
}

fn json(s: &str) -> serde_json::Value {
    serde_json::from_str(s).unwrap()
}

struct Transcripts {
    records: Vec<Vec<u8>>,
    bodies: Vec<Vec<u8>>,
    preambles: Vec<Vec<u8>>,
    msg1: Vec<Vec<u8>>,
    msg2: Vec<Vec<u8>>,
    msg3: Vec<Vec<u8>>,
    payload2: Vec<Vec<u8>>,
    payload3: Vec<Vec<u8>>,
}

fn transcripts() -> Transcripts {
    let mut t = Transcripts {
        records: vec![],
        bodies: vec![],
        preambles: vec![],
        msg1: vec![],
        msg2: vec![],
        msg3: vec![],
        payload2: vec![],
        payload3: vec![],
    };
    for doc in [include_str!("../../docs/test-vectors.json"), include_str!("../../docs/test-vectors-rust.json")] {
        for s in json(doc)["sessions"].as_array().unwrap() {
            let h = |k: &str| unhex(s[k].as_str().unwrap());
            for r in s["records"].as_array().unwrap() {
                t.records.push(unhex(r["plaintext"].as_str().unwrap()));
                t.bodies.push(unhex(r["record"].as_str().unwrap())[4..].to_vec());
            }
            t.preambles.push(h("client_preamble"));
            t.msg1.push(h("msg1"));
            t.msg2.push(h("msg2"));
            t.msg3.push(h("msg3"));
            t.payload2.push(h("msg2_payload"));
            t.payload3.push(h("msg3_payload"));
        }
    }
    t
}

fn tiny_png() -> Vec<u8> {
    let img = clipboard::Rgba { w: 3, h: 2, px: (0..24).map(|i| (i * 11) as u8).collect() };
    clipboard::rgba_to_png(&img).unwrap()
}

/// One of every message either side sends, plus the reference encodings of PROTOCOL.md.
fn message_corpus() -> Vec<Vec<u8>> {
    let mut v = transcripts().records;
    for doc in [include_str!("../../docs/file-transfer-vectors.json"), include_str!("../../docs/display-vectors.json")] {
        for m in json(doc)["messages"].as_array().unwrap() {
            v.push(unhex(m["hex"].as_str().unwrap()));
        }
    }
    let cfg = VideoConfig { width: 1920, height: 1080, codec: Codec::Hevc, chroma: 0, color: 0, scale: 2.0 };
    let host = [
        HostMsg::AuthResult { code: 0 },
        HostMsg::PairReveal { nonce: [7; 32] },
        HostMsg::ServerHello { version: 2, host_name: "host".into(), config: cfg },
        HostMsg::VideoConfig(cfg),
        HostMsg::SharpLayerConfig(VideoConfig { chroma: 1, ..cfg }),
        HostMsg::Pong { client_time_us: 1, host_time_us: 2 },
        HostMsg::VideoFrame { frame_id: 7, capture_time_us: 9, flags: FRAME_FLAG_RECTS, rects: Some(vec![Rect { x: 0, y: 16, w: 32, h: 48 }]), data: vec![0, 0, 0, 1, 0x26, 1] },
        HostMsg::CursorPos { x: 0.5, y: 0.5, visible: true },
        HostMsg::CursorShape { shape_id: 3, w: 2, h: 2, hot_x: 1, hot_y: 1, bgra: vec![0; 16] },
        HostMsg::CursorShapeRef { shape_id: 3 },
        HostMsg::Clipboard(ClipboardData { seq: 1, text: Some("hi\n".into()), png: Some(tiny_png()) }),
        HostMsg::ClipboardCaps { formats: 3, max_bytes: 16 << 20 },
        HostMsg::AudioConfig(AudioConfig { codec: 1, sample_rate: 48000, channels: 2, frame_samples: 480 }),
        HostMsg::AudioFrame { seq: 7, capture_time_us: 1_000_000, data: vec![1, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0x80] },
        HostMsg::DisplayInfo { preference: 0, mode_w: 1920, mode_h: 1080, hidpi: true },
    ];
    v.extend(host.iter().map(HostMsg::encode));
    for h in [
        "81 07000000 40420f0000000000 01 dc050000 40060000 48260000 ac260000 74270000",
        "05048007380401",
        "16 03",
        "80 01",
        "82 7800 01 f82a0000 b0040000 2c010000 08070000 90010000 f41a0000 60540000 ffffffff",
        "100000803e0000403f",
    ] {
        v.push(unhex(&h.replace(' ', "")));
    }
    v
}

/// Every sanitized component must be usable as one path element on Windows and macOS.
fn component_is_safe(c: &str) -> bool {
    !c.is_empty()
        && c != "."
        && c != ".."
        && c.len() <= 201 // 200 + the "_" of §6.3 step 5
        && !c.ends_with('.')
        && !c.ends_with(' ')
        && !c.chars().any(|ch| (ch as u32) < 0x20 || ch == '\u{7f}' || "/\\:*?\"<>|".contains(ch))
}

#[test]
fn fuzz_host_messages() {
    let corpus = message_corpus();
    let mut rng = Rng::new(seed());
    let (mut decoded, n) = (0usize, iters() * 8);
    let limits = files::Limits::default();
    let mut displays = crate::displays::DisplayState::default();
    for _ in 0..n {
        let m = mutate(&corpus[rng.below(corpus.len())], &mut rng, &corpus);
        guard("HostMsg::decode", &m, || {
            if let Ok(h) = HostMsg::decode(m.clone()) {
                decoded += 1;
                if !matches!(h, HostMsg::Unknown { .. }) {
                    assert!(HostMsg::decode(h.encode()).is_ok(), "re-encoded {h:?} doesn't decode");
                }
                match &h {
                    HostMsg::File(FileMsg::Offer { id, total_bytes, files }) => {
                        if let Ok(rel) = files::validate_offer(*id, *total_bytes, files, &limits, true) {
                            for comps in rel {
                                assert!(!comps.is_empty() && comps.len() <= 32 && comps.iter().all(|c| component_is_safe(c)), "unsafe accepted path {comps:?}");
                            }
                        }
                    }
                    HostMsg::DisplayList { streamed, selected, displays: list } => {
                        let remembered = list.first().map(crate::displays::DisplayIdentity::of);
                        displays.apply_list(*streamed, *selected, list.clone());
                        let _ = (displays.cycle(1), displays.cycle(-1), displays.position(*streamed), displays.name(*selected));
                        let _ = crate::displays::restore_choice(remembered.as_ref(), &displays);
                        for d in &displays.displays {
                            let _ = crate::displays::label(d);
                        }
                    }
                    HostMsg::DisplayChanged { display_id, reason, requested } => {
                        let _ = crate::displays::remember_after(&displays, *display_id, *reason, *requested);
                        let _ = crate::displays::changed_toast(&displays, *display_id, *reason, *requested, false);
                    }
                    HostMsg::Clipboard(c) => {
                        if let Some(p) = &c.png {
                            if clipboard::png_refusal(p).is_none() {
                                let _ = clipboard::png_to_rgba(p);
                            }
                        }
                    }
                    _ => {}
                }
            }
        });
        guard("ClientMsg::decode", &m, || {
            if let Ok(c) = ClientMsg::decode(&m) {
                decoded += 1;
                assert!(ClientMsg::decode(&c.encode()).is_ok(), "re-encoded {c:?} doesn't decode");
            }
        });
    }
    assert!(decoded > n / 8, "only {decoded} of {n} mutated messages decoded: corpus or mutator broken");
}

#[test]
fn fuzz_handshake() {
    let t = transcripts();
    let all: Vec<Vec<u8>> = [&t.preambles, &t.msg1, &t.msg2, &t.msg3].into_iter().flatten().cloned().collect();
    let mut rng = Rng::new(seed() ^ 1);
    let identity = StaticSecret::from([0x42; 32]);
    for _ in 0..iters() {
        let k = rng.below(t.msg1.len());
        let pre = if rng.below(4) == 0 { mutate(&t.preambles[k], &mut rng, &all) } else { t.preambles[k].clone() };
        guard("parse_client_preamble", &pre, || {
            let _ = handshake::parse_client_preamble(&pre);
        });
        let hp = mutate(&handshake::host_preamble(2, 0), &mut rng, &all);
        guard("parse_host_preamble", &hp, || {
            if let Ok(a) = <[u8; handshake::HOST_PREAMBLE_LEN]>::try_from(hp.as_slice()) {
                let _ = handshake::parse_host_preamble(&a);
            }
        });
        let p2 = mutate(&t.payload2[k], &mut rng, &all);
        guard("HostInfo::decode", &p2, || {
            let _ = HostInfo::decode(&p2);
        });
        let p3 = mutate(&t.payload3[k], &mut rng, &all);
        guard("ViewerInfo::decode", &p3, || {
            let _ = ViewerInfo::decode(&p3);
        });
        // Viewer (the real attack surface): its own msg1, then a mutated msg2 from the "host".
        let m2 = mutate(&t.msg2[k], &mut rng, &all);
        guard("ViewerHandshake::read_msg2", &m2, || {
            let mut v = ViewerHandshake::new(identity.clone(), "fuzz", None, None);
            let _ = v.first_flight();
            let _ = v.read_msg2(&m2, 2);
        });
        // Host engine (tests/tooling): mutated msg1, or a real msg1 followed by a mutated msg3.
        let m1 = if rng.below(2) == 0 { mutate(&t.msg1[k], &mut rng, &all) } else { t.msg1[k].clone() };
        let m3 = mutate(&t.msg3[k], &mut rng, &all);
        guard("HostHandshake", &[m1.as_slice(), &m3].concat(), || {
            if let Ok(mut h) = HostHandshake::read_first(identity.clone(), &pre, &m1, None, None) {
                let _ = h.write_msg2(1);
                let _ = h.read_msg3(&m3);
            }
        });
        // Records: no mutation of a real record may authenticate under a random key, or panic.
        let body = &t.bodies[rng.below(t.bodies.len())];
        let mb = mutate(body, &mut rng, &t.bodies);
        guard("Opener::open", &mb, || {
            let mut o = Opener::new(&[rng.byte(); 32]);
            assert!(mb == *body || o.open(&mb).is_err(), "forged record accepted");
        });
        // Framed record reader: arbitrary length prefixes.
        let framed = mutate(&unhex(&format!("{:08x}", 0x11000000u32)), &mut rng, &t.bodies);
        guard("Opener::read_record_max", &framed, || {
            let mut o = Opener::new(&[1; 32]);
            let _ = o.read_record_max(&mut std::io::Cursor::new(&framed), &mut Vec::new(), 64 * 1024);
        });
    }
}

#[test]
fn fuzz_file_names() {
    let v = json(include_str!("../../docs/file-transfer-vectors.json"));
    let paths: Vec<Vec<u8>> = v["paths"].as_array().unwrap().iter().map(|p| p["in"].as_str().unwrap().as_bytes().to_vec()).collect();
    let alphabet = [
        "/", "\\", ".", "..", ":", " ", "\0", "\u{1f}", "\u{7f}", "C:", "con", "CON.txt", "lpt\u{b9}", "a", "é", "e\u{301}", "\u{202e}", "\u{200b}", "\u{feff}", "*", "?",
        "\"", "<", ">", "|", "~", "%2e", "日本", "😀",
    ];
    let long = "x".repeat(120);
    let mut rng = Rng::new(seed() ^ 2);
    for _ in 0..iters() * 2 {
        let p = if rng.below(2) == 0 {
            String::from_utf8_lossy(&mutate(&paths[rng.below(paths.len())], &mut rng, &paths)).into_owned()
        } else {
            (0..1 + rng.below(12)).map(|_| if rng.below(30) == 0 { long.as_str() } else { alphabet[rng.below(alphabet.len())] }).collect()
        };
        guard("sanitize_path", p.as_bytes(), || {
            if let Ok(comps) = files::sanitize_path(&p) {
                assert!(!comps.is_empty() && comps.len() <= 32 && comps.iter().all(|c| component_is_safe(c)), "unsafe: {p:?} -> {comps:?}");
                let raw: Vec<&str> = p.split('/').collect();
                assert!(!p.starts_with('/') && !p.starts_with('\\') && !raw.iter().any(|c| c.is_empty() || *c == "." || *c == ".."), "accepted {p:?}");
                for c in &comps {
                    let _ = files::with_suffix(c, 2 + rng.below(9998) as u32, rng.below(2) == 0);
                }
            }
        });
    }
}

#[test]
fn fuzz_media_parsers() {
    // Clipboard images (PNG from the host; DIB from local apps) and Annex-B bitstreams.
    let png = tiny_png();
    let mut dib = vec![0u8; 40];
    dib[0] = 40;
    dib[4] = 2;
    dib[8] = 2;
    dib[12] = 1;
    dib[14] = 32;
    dib.extend_from_slice(&[0x10; 16]);
    let clips: Vec<Vec<u8>> = vec![include_bytes!("../assets/hevc_main_420_8.h265")[..4096].to_vec(), include_bytes!("../assets/h264_high_420_8.h264")[..4096].to_vec()];
    let images = vec![png.clone(), dib.clone()];
    let mut rng = Rng::new(seed() ^ 3);
    let mut jb = JitterBuffer::new(48000, 2, JitterParams::default());
    for i in 0..iters() {
        let p = mutate(&png, &mut rng, &images);
        guard("png", &p, || {
            if clipboard::png_refusal(&p).is_none() {
                let _ = clipboard::png_to_rgba(&p);
            }
            let _ = clipboard::png_dimensions(&p);
            let _ = clipboard::png_trim(&p);
        });
        let d = mutate(&dib, &mut rng, &images);
        guard("dib_to_rgba", &d, || {
            let _ = clipboard::dib_to_rgba(&d);
        });
        let c = mutate(&clips[i % 2], &mut rng, &clips);
        guard("annexb", &c, || {
            let codec = if i % 2 == 0 { Codec::Hevc } else { Codec::H264 };
            let _ = annexb::split_access_units(codec, &c);
            let _ = annexb::hevc_sps_info(&c);
            for n in annexb::nals(&c) {
                let _ = (annexb::is_vcl(codec, n), annexb::is_keyframe_nal(codec, n));
            }
        });
        let pcm = mutate(&[1, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0, 0x80], &mut rng, &[]);
        guard("JitterBuffer::push", &pcm, || {
            if rng.below(64) == 0 {
                jb.reset([8000, 44100, 48000, 96000][rng.below(4)], 1 + rng.below(8));
            }
            let _ = jb.push(rng.next() as u32, rng.next(), &pcm);
            let mut out = vec![0f32; 480 * jb.channels()];
            jb.pull(&mut out);
        });
    }
}

#[test]
fn mutator_is_deterministic() {
    let corpus = message_corpus();
    let run = |s| {
        let mut r = Rng::new(s);
        (0..200).map(|i| mutate(&corpus[i % corpus.len()], &mut r, &corpus)).collect::<Vec<_>>()
    };
    assert_eq!(run(7), run(7));
    assert_ne!(run(7), run(8));
}

/// Regression tests for the hardening findings (each was a panic, a debug-overflow or a
/// resource blow-up on hostile input before the fix).
mod regressions {
    use super::*;
    use crate::net::ClockSync;
    use std::time::Instant;

    fn entry(path: String) -> FileEntry {
        FileEntry { path, size: 0, mtime_ms: 0 }
    }

    #[test]
    fn offer_conflict_check_is_cheap_on_hostile_offers() {
        // 10 000 files × 32 components × ~120 bytes: the old prefix-set check built ~1 GB of
        // strings for this; the sorted check stays linear-ish.
        let comp = "x".repeat(120);
        let mut files: Vec<FileEntry> = (0..10_000).map(|i| entry(format!("{i:05}{}", format!("/{comp}").repeat(31)))).collect();
        files.push(entry(format!("00000{}", format!("/{comp}").repeat(30)))); // a folder of file 0
        let limits = files::Limits { max_total_bytes: 1, max_files: 20_000 };
        let t = Instant::now();
        let r = files::validate_offer(1, 0, &files, &limits, false);
        assert!(matches!(r, Err((s, _)) if s == files::status::BAD_NAME), "{r:?}");
        assert!(t.elapsed().as_secs_f64() < 20.0, "validate_offer took {:?}", t.elapsed());
    }

    #[test]
    fn offer_conflicts_still_detected() {
        let l = files::Limits::default();
        let v = |paths: &[&str]| files::validate_offer(1, 0, &paths.iter().map(|p| entry(p.to_string())).collect::<Vec<_>>(), &l, false);
        assert!(v(&["a", "A/b"]).is_err());
        assert!(v(&["x/y/z", "X/Y"]).is_err());
        assert!(v(&["a b", "a/c", "a.txt"]).is_ok_and(|r| r.len() == 3), "'a' is only a folder");
        assert!(v(&["ab", "a/b"]).is_ok());
        assert!(v(&["a/b", "a/c", "d"]).is_ok());
    }

    #[test]
    fn truncation_cannot_produce_a_device_name() {
        // §6.3: "CON" + 197 spaces + "xyz" used to come out as "CON".
        for (input, bad) in [
            (format!("CON{}xyz", " ".repeat(197)), "CON"),
            (format!("NUL{}abcdefgh.txt", " ".repeat(193)), "NUL"),
            (format!("com1{}.y", ".".repeat(250)), "com1"),
        ] {
            let out = files::sanitize_component(&input);
            let base = out.split('.').next().unwrap().trim_end_matches(' ').to_ascii_uppercase();
            assert_ne!(base, bad.to_ascii_uppercase(), "{input:?} -> {out:?}");
            assert!(out.starts_with('_') && out.len() <= 201, "{out:?}");
        }
    }

    #[test]
    fn hostile_timestamps_do_not_overflow() {
        // Pong with a host time past i64::MAX; Pongs whose t_mid goes backwards.
        let mut c = ClockSync::default();
        c.on_pong(0, 0x8000_0000_0000_0000, 1_000);
        c.on_pong(19_700_000, 5, 20_700_000);
        c.on_pong(19_260_000, 5, 20_710_000);
        for i in 0..4 {
            c.on_pong(i * 10_000_000, u64::MAX - i, i * 10_000_000 + 100);
        }
        let _ = (c.host_to_client_us(u64::MAX), c.client_to_host_us(u64::MAX));
        // A flood of Pongs keeps the clock-sync window bounded.
        for i in 0..10_000u64 {
            c.on_pong(1_000_000, i, 1_000_100);
        }
        assert!(c.window_samples() <= 256, "{}", c.window_samples());
        // FrameTiming with a capture time near u64::MAX: offsets are "unknown", not overflow.
        let ft = FrameTiming { frame_id: 1, capture_us: u64::MAX - 1, flags: 0, callback: 5, submit: 5, encoded: 5, enqueued: 5, sent: 5 };
        assert_eq!(ft.at(5), None);
        // Audio frame stamped near u64::MAX.
        let mut jb = JitterBuffer::new(48000, 2, JitterParams::default());
        assert!(jb.push(1, u64::MAX - 4, &[0; 8]));
        assert!(jb.push(2, u64::MAX, &[0; 8]));
    }

    #[test]
    fn display_names_stay_bounded() {
        let mut s = crate::displays::DisplayState::default();
        for round in 0..100u32 {
            let list = (0..255).map(|i| MacDisplay { id: round * 255 + i, name: "x".repeat(64), ..Default::default() }).collect();
            s.apply_list(0, 0, list);
        }
        assert!(s.names.len() <= 512, "{}", s.names.len());
        assert_eq!(s.name(99 * 255), "x".repeat(64), "current displays are still named");
    }

    #[test]
    fn rect_count_does_not_drive_the_allocation() {
        // 16 bytes claiming 65535 rects: an error, without a 512 KiB reservation first.
        let m = unhex("4000000000000000000000000008ffff");
        assert!(HostMsg::decode(m).is_err());
    }

    #[test]
    fn png_decoder_limits() {
        // A 1×1 PNG carrying a 64 MiB (zero-filled, so tiny when compressed) ICC profile: the
        // decoder must not inflate it.
        let mut info = png::Info::with_size(1, 1);
        info.color_type = png::ColorType::Rgba;
        info.bit_depth = png::BitDepth::Eight;
        info.icc_profile = Some(std::borrow::Cow::Owned(vec![0u8; 64 << 20]));
        let mut out = Vec::new();
        {
            let enc = png::Encoder::with_info(&mut out, info).unwrap();
            let mut w = enc.write_header().unwrap();
            w.write_image_data(&[1, 2, 3, 4]).unwrap();
        }
        assert!(out.len() < 1 << 20, "test PNG is {} bytes", out.len());
        assert!(clipboard::png_refusal(&out).is_none());
        let img = clipboard::png_to_rgba(&out).expect("the ICC profile is skipped, the pixel decodes");
        assert_eq!((img.w, img.h, img.px.as_slice()), (1, 1, &[1u8, 2, 3, 4][..]));
        // Images larger than the decoder budget still decode (our buffer isn't counted).
        let (w, h) = (2560u32, 2048u32);
        let big = clipboard::Rgba { w, h, px: (0..w * h * 4).map(|i| (i % 251) as u8).collect() };
        let png = clipboard::rgba_to_png(&big).unwrap();
        assert_eq!(clipboard::png_to_rgba(&png).unwrap(), big);
    }

    #[test]
    fn sps_parser_survives_truncated_nals() {
        assert_eq!(annexb::hevc_sps_info(&[0, 0, 1, 0x42]), None);
        assert_eq!(annexb::hevc_sps_info(&[0, 0, 1, 0x42, 0x01]), None);
    }

    #[test]
    fn dib_masks_wider_than_16_bits() {
        // BITMAPV5-style header with a 32-bit red mask and a mask with holes.
        let mut dib = vec![0u8; 56];
        dib[0] = 56;
        dib[4] = 1;
        dib[8] = 1;
        dib[12] = 1;
        dib[14] = 32;
        dib[16] = 3; // BI_BITFIELDS
        dib[40..44].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        dib[44..48].copy_from_slice(&0x00F0_F00Fu32.to_le_bytes());
        dib[48..52].copy_from_slice(&0x0000_00FFu32.to_le_bytes());
        dib.extend_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
        let img = clipboard::dib_to_rgba(&dib).unwrap();
        assert_eq!(&img.px[..3], &[255, 255, 255]);
    }
}
