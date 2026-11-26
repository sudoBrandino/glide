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

/// The managed-mode approval prompt (docs/ENTERPRISE.md §6.4): the same dialog, naming the user
/// and email. Decline is the default button, Accept is enabled after 1 s, and the agent cancels
/// it after 50 s (the countdown shows that). If the dialog can't be shown, the request is declined.
pub struct CloudPrompt;

impl crate::cloud::host::HostUi for CloudPrompt {
    fn approve(&self, o: &crate::cloud::api::SessionOffer, cancel: Arc<AtomicBool>) -> crate::cloud::host::Approval {
        use crate::cloud::host::{Approval, APPROVAL_TIMEOUT};
        use crate::win::prompt::{ask, PromptSpec};
        let start = std::time::Instant::now();
        let viewer = crate::host::trust::display_name(&o.viewer.name);
        let spec = PromptSpec {
            title: "Glide — Remote session request".into(),
            t: PairText {
                text: format!("{} from your organization asks to see and control this PC (from “{viewer}”).\nAccept only if you expect this.", o.user.label()),
                code: String::new(),
                detail: format!("This session: {}.\nYou can end it at any time from the Glide Host icon (End session).", o.permissions.describe()),
            },
            confirm: "Accept".into(),
            cancel: "Decline".into(),
            code_pt: 12,
            on_confirm: None,
            live_code: Some(Box::new(move || format!("Declines automatically in {} s", APPROVAL_TIMEOUT.saturating_sub(start.elapsed()).as_secs()))),
        };
        match ask(None, spec, cancel) {
            Ok(true) => Approval::Accept,
            Ok(false) => Approval::Decline,
            Err(e) => {
                log(&format!("managed session request: {e}; declining"));
                Approval::Decline
            }
        }
    }

    fn notice(&self, text: &str) {
        log(text);
    }
}
