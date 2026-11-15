//! The PC-side pairing confirmation: the viewer's `IDD_PAIR` dialog (`win::prompt`) with the code,
//! both fingerprints and the Mac's address. Cancel is the default button, "Codes Match — Pair" is
//! enabled only 1 s after the dialog appears, and the dialog never steals the foreground (its
//! taskbar button flashes). Falls back to `fallback` (the console) when the dialog can't be shown
//! (no interactive desktop, e.g. an SSH session).

use crate::host::auth::{LocalConfirm, PairRequest};
use crate::host::log;
use crate::win::prompt::{ask_pairing_titled, PairText};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

pub struct DialogConfirm {
    pub fallback: Arc<dyn LocalConfirm>,
}

impl LocalConfirm for DialogConfirm {
    fn confirm(&self, req: &PairRequest, cancel: Arc<AtomicBool>) -> bool {
        let t = PairText {
            text: format!(
                "A Mac at {} (“{}”) asks to control this PC.\nAllow it only if you started pairing on that Mac and it shows the same code.",
                req.peer, req.viewer_name
            ),
            code: req.code.clone(),
            detail: format!(
                "Mac (viewer) key: {}\nThis PC's key: {}\nOnce paired, this Mac can see this screen and use the keyboard and mouse.",
                req.viewer_fingerprint, req.host_fingerprint
            ),
        };
        match ask_pairing_titled(None, t, cancel.clone(), "Glide — Pair with a Mac") {
            Ok(ok) => ok,
            Err(e) => {
                log(&format!("pairing: {e}; asking on the console instead"));
                self.fallback.confirm(req, cancel)
            }
        }
    }
}
