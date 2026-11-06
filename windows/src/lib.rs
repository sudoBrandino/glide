//! Glide Windows viewer client.
//!
//! Platform-independent modules (`protocol`, `crypto`, `net`, `hid`, `annexb`, `bench`)
//! build and test on any OS; the Windows-only decoder/renderer/UI live in `win`.

pub mod annexb;
pub mod audio;
pub mod bench;
pub mod clipboard;
pub mod crypto;
pub mod hid;
pub mod net;
pub mod protocol;
pub mod util;

#[cfg(windows)]
pub mod win;
