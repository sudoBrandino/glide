//! Glide **host** for Windows (`glide-host.exe`): the machine being controlled (docs/WINDOWS_HOST.md).
//!
//! The Noise responder side of docs/PROTOCOL.md. Platform-independent parts live here and are
//! unit-tested on any OS:
//! - `trust`: host.json (paired viewers, port), the pairing window and the two-party vote, the
//!   host identity file;
//! - `auth`: the host side of the handshake and auth phase (§1–§2) over a TCP stream, with
//!   rate limiting (§2.5), pre-auth deadlines and record caps;
//! - `stream`: decoding + validating viewer messages after authentication (§3);
//! - `input`: HID usage → Windows scancode, held-key tracking, wheel accumulation, absolute
//!   mouse mapping;
//! - `video`: capture/encode sizing (`ViewSize`), codec choice, bitrate, Annex-B helpers and
//!   cursor bitmap conversion.
//!
//! The Windows-only pipeline (DXGI Desktop Duplication, D3D11 video processor, Media Foundation
//! encoder, SendInput, cursor polling) is in `host::win`.

pub mod auth;
pub mod input;
pub mod stream;
pub mod trust;
pub mod video;

#[cfg(windows)]
pub mod win;

/// Default TCP port of the Windows host (docs/WINDOWS_HOST.md: 7420 is the Windows viewer's).
pub const DEFAULT_PORT: u16 = 7421;

/// One log line on stderr with a wall-clock time stamp (UTC, `HH:MM:SS.mmm`).
pub fn log(line: &str) {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let ms = now.as_millis() as u64;
    let (h, m, s) = ((ms / 3_600_000) % 24, (ms / 60_000) % 60, (ms / 1000) % 60);
    eprintln!("{h:02}:{m:02}:{s:02}.{:03} {line}", ms % 1000);
}
