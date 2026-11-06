//! Glide Windows viewer client.
//!
//! Platform-independent modules (`protocol`, `crypto`, `net`, `hid`, `annexb`, `bench`)
//! build and test on any OS; the Windows-only decoder/renderer/UI live in `win`.

pub mod annexb;
pub mod bench;
pub mod clipboard;
pub mod config;
pub mod crypto;
pub mod hid;
pub mod hotkeys;
pub mod hud;
pub mod net;
pub mod peers;
pub mod protocol;
pub mod util;

#[cfg(windows)]
pub mod win;
