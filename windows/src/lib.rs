//! Glide Windows viewer client.
//!
//! Platform-independent modules (`protocol`, `crypto`, `net`, `hid`, `annexb`, `bench`)
//! build and test on any OS; the Windows-only decoder/renderer/UI live in `win`.

pub mod annexb;
pub mod audio;
pub mod bench;
pub mod clipboard;
pub mod config;
pub mod crypto;
pub mod handshake;
pub mod hid;
pub mod hotkeys;
pub mod hud;
pub mod identity;
pub mod net;
pub mod noise;
pub mod peers;
pub mod protocol;
pub mod util;

#[cfg(test)]
pub(crate) mod testhost;

#[cfg(windows)]
pub mod win;
