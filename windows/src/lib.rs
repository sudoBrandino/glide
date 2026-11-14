//! Glide Windows viewer client.
//!
//! Platform-independent modules (`protocol`, `crypto`, `net`, `hid`, `annexb`, `bench`,
//! `latency`, `blockcode`)
//! build and test on any OS; the Windows-only decoder/renderer/UI live in `win`.

pub mod annexb;
pub mod audio;
pub mod bench;
pub mod blockcode;
pub mod clipboard;
pub mod config;
pub mod connbar;
pub mod crypto;
pub mod files;
pub mod handshake;
pub mod hid;
pub mod hotkeys;
pub mod hud;
pub mod identity;
pub mod latency;
pub mod menu_model;
pub mod net;
pub mod noise;
pub mod peers;
pub mod protocol;
pub mod util;
pub mod version;

#[cfg(test)]
pub(crate) mod testhost;

#[cfg(windows)]
pub mod win;
