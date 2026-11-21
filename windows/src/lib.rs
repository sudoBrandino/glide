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
pub mod connections;
pub mod crypto;
pub mod displays;
pub mod files;
pub mod handshake;
pub mod hid;
pub mod host;
pub mod hotkeys;
pub mod hud;
pub mod identity;
pub mod input;
pub mod latency;
pub mod menu_model;
pub mod net;
pub mod noise;
pub mod peers;
pub mod protocol;
pub mod settings;
pub mod setup;
pub mod util;
pub mod version;

#[cfg(test)]
mod fuzz_tests;
#[cfg(test)]
pub(crate) mod testhost;

#[cfg(windows)]
pub mod win;
