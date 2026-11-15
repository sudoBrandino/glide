//! Small helpers: hex, monotonic clock, percentiles, JSON string escaping, test hooks.

use std::sync::OnceLock;
use std::time::Instant;

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex")).collect()
}

/// Built with the `test-hooks` cargo feature (off by default, never in a release build).
pub const TEST_HOOKS: bool = cfg!(feature = "test-hooks");

/// Environment variables that answer dialogs, dump captures or act for the user (for SSH /
/// session 0 smoke tests where nobody can click). They work only in a `test-hooks` build: in a
/// release viewer a variable left set (e.g. with `setx`) must never confirm a pairing by itself.
pub const TEST_HOOK_VARS: &[&str] = &[
    "GLIDE_PAIR_CONFIRM",
    "GLIDE_PROMPT_DUMP",
    "GLIDE_SETUP_ANSWER",
    "GLIDE_SETUP_DUMP",
    "GLIDE_DUMP_FRAME",
    "GLIDE_DUMP_MENU",
    "GLIDE_TEST_ACTIONS",
    "GLIDE_TEST_SEND_FILES",
];

/// The value of test hook `name` (one of `TEST_HOOK_VARS`); always None without `test-hooks`.
pub fn test_hook(name: &str) -> Option<String> {
    test_hook_in(TEST_HOOKS, name, |n| std::env::var(n).ok())
}

fn test_hook_in(enabled: bool, name: &str, env: impl Fn(&str) -> Option<String>) -> Option<String> {
    debug_assert!(TEST_HOOK_VARS.contains(&name), "{name} is not a listed test hook");
    if enabled {
        env(name)
    } else {
        None
    }
}

/// Test hook variables that are set but ignored because this build has no `test-hooks`.
pub fn ignored_test_hooks() -> Vec<&'static str> {
    ignored_in(TEST_HOOKS, |n| std::env::var_os(n).is_some())
}

fn ignored_in(enabled: bool, is_set: impl Fn(&str) -> bool) -> Vec<&'static str> {
    if enabled {
        return Vec::new();
    }
    TEST_HOOK_VARS.iter().copied().filter(|v| is_set(v)).collect()
}

static EPOCH: OnceLock<Instant> = OnceLock::new();

/// Client monotonic microseconds since process start.
pub fn now_us() -> u64 {
    EPOCH.get_or_init(Instant::now).elapsed().as_micros() as u64
}

/// Nearest-rank percentile over an unsorted slice (`p` in 0..=100).
pub fn percentile(values: &[f64], p: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut v = values.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let rank = ((p / 100.0) * v.len() as f64).ceil() as usize;
    Some(v[rank.clamp(1, v.len()) - 1])
}

pub fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn json_opt(v: Option<f64>) -> String {
    match v {
        Some(x) if x.is_finite() => format!("{x:.3}"),
        _ => "null".into(),
    }
}

/// Aspect-fit `vw x vh` into `cw x ch`; returns integer (x, y, w, h). Upscales as needed.
pub fn letterbox(cw: u32, ch: u32, vw: u32, vh: u32) -> (i32, i32, i32, i32) {
    if cw == 0 || ch == 0 || vw == 0 || vh == 0 {
        return (0, 0, cw as i32, ch as i32);
    }
    let (w, h) = if (cw as u64) * (vh as u64) <= (ch as u64) * (vw as u64) {
        // width-limited
        (cw, ((cw as u64 * vh as u64 + vw as u64 / 2) / vw as u64) as u32)
    } else {
        (((ch as u64 * vw as u64 + vh as u64 / 2) / vh as u64) as u32, ch)
    };
    let (w, h) = (w.min(cw), h.min(ch));
    (((cw - w) / 2) as i32, ((ch - h) / 2) as i32, w as i32, h as i32)
}

/// Where to draw a `vw x vh` video in a `bw x bh` back buffer. Same as `letterbox`, except that
/// when the video already fits and is within ~6% of the buffer size it is drawn 1:1, centered
/// (a thin black border beats a blurry 1.01x resample of text).
pub fn present_rect(bw: u32, bh: u32, vw: u32, vh: u32) -> (i32, i32, i32, i32) {
    if vw > 0 && vh > 0 && vw <= bw && vh <= bh && (bw - vw) <= bw / 16 && (bh - vh) <= bh / 16 {
        return (((bw - vw) / 2) as i32, ((bh - vh) / 2) as i32, vw as i32, vh as i32);
    }
    letterbox(bw, bh, vw, vh)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn present_rect_prefers_1to1() {
        assert_eq!(present_rect(3072, 1728, 3072, 1728), (0, 0, 3072, 1728));
        assert_eq!(present_rect(3072, 1728, 3070, 1726), (1, 1, 3070, 1726));
        assert_eq!(present_rect(3072, 1728, 3072, 1700), (0, 14, 3072, 1700));
        // big differences scale as before
        assert_eq!(present_rect(3072, 1728, 3840, 2160), (0, 0, 3072, 1728));
        assert_eq!(present_rect(3840, 2160, 2560, 1440), (0, 0, 3840, 2160));
    }

    #[test]
    fn letterboxing() {
        assert_eq!(letterbox(2560, 1440, 2560, 1440), (0, 0, 2560, 1440));
        assert_eq!(letterbox(3840, 2160, 2560, 1440), (0, 0, 3840, 2160));
        assert_eq!(letterbox(2560, 1600, 2560, 1440), (0, 80, 2560, 1440));
        assert_eq!(letterbox(2000, 1440, 2560, 1440), (0, 157, 2000, 1125));
        assert_eq!(letterbox(3000, 1440, 2560, 1440), (220, 0, 2560, 1440));
        assert_eq!(letterbox(0, 10, 5, 5), (0, 0, 0, 10));
    }

    #[test]
    fn percentiles() {
        let v: Vec<f64> = (1..=100).map(|x| x as f64).collect();
        assert_eq!(percentile(&v, 50.0), Some(50.0));
        assert_eq!(percentile(&v, 95.0), Some(95.0));
        assert_eq!(percentile(&v, 100.0), Some(100.0));
        assert_eq!(percentile(&[], 50.0), None);
        assert_eq!(json_str("a\"b\n"), "\"a\\\"b\\n\"");
        assert_eq!(unhex(&hex(&[0, 255, 16])), vec![0, 255, 16]);
    }

    #[test]
    fn test_hooks_need_the_feature() {
        // A release build (no `test-hooks`) never sees GLIDE_PAIR_CONFIRM, even when it is set.
        let env = |n: &str| (n == "GLIDE_PAIR_CONFIRM").then(|| "yes".to_string());
        assert_eq!(test_hook_in(false, "GLIDE_PAIR_CONFIRM", env), None);
        assert_eq!(test_hook_in(true, "GLIDE_PAIR_CONFIRM", env).as_deref(), Some("yes"));
        assert_eq!(test_hook_in(true, "GLIDE_SETUP_ANSWER", env), None);
        let set = |n: &str| n == "GLIDE_PAIR_CONFIRM" || n == "GLIDE_SETUP_DUMP";
        assert_eq!(ignored_in(false, set), vec!["GLIDE_PAIR_CONFIRM", "GLIDE_SETUP_DUMP"]);
        assert!(ignored_in(true, set).is_empty());
        assert_eq!(TEST_HOOKS, cfg!(feature = "test-hooks"));
    }
}
