//! Session permission enforcement (docs/ENTERPRISE.md §6.3), on the plaintext of Glide records
//! (`u8 type ‖ payload`, PROTOCOL.md §2.1) so it applies at the transport choke points: what the
//! viewer sends and what it accepts, what the host sends and what it accepts.
//!
//! - `control: false`: no input messages (0x10–0x14, 0x17–0x19) and nothing the viewer pushes:
//!   clipboard and file data toward the host are refused too (`effective`).
//! - `clipboard` / `files`: the data's direction (`to_host` = viewer → host). File messages
//!   (0x71–0x77) belong to a transfer whose id says who sends the data (PROTOCOL.md §6.2: the
//!   host's ids have bit 31 set), so every message of a forbidden transfer is refused, whichever
//!   way it travels — except declines (`FileAnswer` with a nonzero status) and `FileCancel`,
//!   which only ever stop a transfer.
//! - `audio`: AudioConfig / AudioFrame (host → viewer), and the viewer's `AudioEnable(true)`.
//! - View only also stops `SetDisplayPreference` (§6.7: the host never changes its display mode
//!   for a view-only viewer; `ViewSize`, which only scales the stream, still flows).

use super::api::{Direction, Permissions};
use crate::protocol::*;

/// Which way a record travels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flow {
    /// Viewer → host (`ClientMsg`).
    FromViewer,
    /// Host → viewer (`HostMsg`).
    FromHost,
}

impl Permissions {
    /// The rules as enforced: view only also stops everything the viewer would push.
    pub fn effective(self) -> Permissions {
        if self.control {
            return self;
        }
        Permissions {
            control: false,
            clipboard: Direction::from_flags(false, self.clipboard.to_viewer()),
            files: Direction::from_flags(false, self.files.to_viewer()),
            audio: self.audio,
        }
    }

    /// One line for prompts and status: what the session allows, from the host's point of view.
    pub fn describe(self) -> String {
        let p = self.effective();
        let dir = |d: Direction| match d {
            Direction::Both => "both ways",
            Direction::ToHost => "to this computer only",
            Direction::ToViewer => "from this computer only",
            Direction::Off => "off",
        };
        format!(
            "{}; clipboard {}; file transfer {}; sound {}",
            if p.control { "can use the keyboard and mouse" } else { "view only" },
            dir(p.clipboard),
            dir(p.files),
            if p.audio { "on" } else { "off" }
        )
    }

    /// Codec caps the viewer advertises in ClientHello for this session (features the session
    /// doesn't allow at all are not negotiated).
    pub fn filter_caps(self, caps: u32) -> u32 {
        let p = self.effective();
        let mut c = caps;
        if p.clipboard == Direction::Off {
            c &= !CAP_CLIPBOARD;
        }
        if p.files == Direction::Off {
            c &= !CAP_FILES;
        }
        if !p.audio {
            c &= !(CAP_AUDIO_PCM | CAP_AUDIO_OPUS);
        }
        c
    }

    /// May a record with plaintext `pt` travel this way in this session?
    pub fn allows(self, flow: Flow, pt: &[u8]) -> bool {
        let p = self.effective();
        let Some(&ty) = pt.first() else { return false };
        let viewer = flow == Flow::FromViewer;
        match ty {
            MSG_MOUSE_MOVE | MSG_MOUSE_BUTTON | MSG_MOUSE_WHEEL | MSG_KEY | MSG_RELEASE_ALL | MSG_SCROLL | MSG_MOUSE_DELTA | MSG_KEY_EXTRA if viewer => {
                // ReleaseAll lets nothing new happen; it is always fine.
                p.control || ty == MSG_RELEASE_ALL
            }
            // View only: the viewer never asks the host to change its display mode (§6.7); the
            // host still scales to the viewer's size (ViewSize is fine).
            MSG_SET_DISPLAY_PREFERENCE if viewer => p.control,
            // No audio: the viewer never asks for it (turning it off is always fine).
            MSG_AUDIO_ENABLE if viewer => p.audio || pt.get(1) == Some(&0),
            MSG_CLIPBOARD => {
                if viewer {
                    p.clipboard.to_host()
                } else {
                    p.clipboard.to_viewer()
                }
            }
            MSG_CLIPBOARD_CAPS if !viewer => p.clipboard != Direction::Off,
            MSG_AUDIO_CONFIG | MSG_AUDIO_FRAME if !viewer => p.audio,
            MSG_FILE_CAPS if !viewer => p.files != Direction::Off,
            MSG_FILE_OFFER..=MSG_FILE_DONE => {
                if pt.len() < 5 {
                    return false;
                }
                let id = u32::from_le_bytes([pt[1], pt[2], pt[3], pt[4]]);
                if ty == MSG_FILE_CANCEL || (ty == MSG_FILE_ANSWER && pt.get(5).is_some_and(|&s| s != 0)) {
                    return true;
                }
                if id & FILE_HOST_ID_BIT != 0 {
                    p.files.to_viewer()
                } else {
                    p.files.to_host()
                }
            }
            MSG_FILE_PULL if viewer => p.files.to_viewer(),
            MSG_FILE_PULL_RESULT if !viewer => p.files.to_viewer() || pt.get(1).is_some_and(|&s| s != 0),
            _ => true,
        }
    }
}

/// A filter closure for `net::Sender::set_filter` / the receive paths.
pub type PlainFilter = std::sync::Arc<dyn Fn(&[u8]) -> bool + Send + Sync>;

pub fn filter(perms: Permissions, flow: Flow) -> PlainFilter {
    std::sync::Arc::new(move |pt: &[u8]| perms.allows(flow, pt))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ClientMsg, ClipboardData, FileMsg, HostMsg};

    fn p(control: bool, clipboard: Direction, files: Direction, audio: bool) -> Permissions {
        Permissions { control, clipboard, files, audio }
    }

    fn clip() -> ClipboardData {
        ClipboardData { seq: 1, text: Some("hi".into()), png: None }
    }

    fn offer(id: u32) -> FileMsg {
        FileMsg::Offer { id, total_bytes: 1, files: vec![crate::protocol::FileEntry { path: "a".into(), size: 1, mtime_ms: 0 }] }
    }

    #[test]
    fn view_only_drops_input_and_pushes() {
        let full = p(true, Direction::Both, Direction::Both, true);
        let view = p(false, Direction::Both, Direction::Both, true);
        let key = ClientMsg::Key { hid_usage: 4, down: true }.encode();
        let mv = ClientMsg::MouseMove { x: 0.5, y: 0.5 }.encode();
        let scroll = ClientMsg::Scroll { flags: 0, dx: 0.0, dy: 1.0 }.encode();
        assert!(full.allows(Flow::FromViewer, &key) && full.allows(Flow::FromViewer, &mv));
        for m in [&key, &mv, &scroll] {
            assert!(!view.allows(Flow::FromViewer, m));
        }
        assert!(view.allows(Flow::FromViewer, &ClientMsg::ReleaseAll.encode()));
        // Viewer pushes are refused, host → viewer data still flows.
        assert!(!view.allows(Flow::FromViewer, &ClientMsg::Clipboard(clip()).encode()));
        assert!(view.allows(Flow::FromHost, &HostMsg::Clipboard(clip()).encode()));
        assert!(!view.allows(Flow::FromViewer, &ClientMsg::File(offer(1)).encode()));
        assert!(view.allows(Flow::FromViewer, &ClientMsg::File(FileMsg::Ack { id: FILE_HOST_ID_BIT | 1, bytes: 1 }).encode()));
        assert_eq!(view.effective().files, Direction::ToViewer);
        // Video control and pings are always fine (the host scales to the viewer's size).
        for m in [ClientMsg::Ping { client_time_us: 1 }, ClientMsg::RequestKeyframe, ClientMsg::ViewSize { view_w: 100, view_h: 100 }] {
            assert!(view.allows(Flow::FromViewer, &m.encode()));
        }
        // ...but view only never changes the host's display mode.
        let pref = ClientMsg::SetDisplayPreference { mode: DISPLAY_PREF_RETINA }.encode();
        assert!(!view.allows(Flow::FromViewer, &pref));
        assert!(full.allows(Flow::FromViewer, &pref));
    }

    #[test]
    fn clipboard_directions_both_sides() {
        let to_host = p(true, Direction::ToHost, Direction::Off, false);
        assert!(to_host.allows(Flow::FromViewer, &ClientMsg::Clipboard(clip()).encode()));
        assert!(!to_host.allows(Flow::FromHost, &HostMsg::Clipboard(clip()).encode()));
        let to_viewer = p(true, Direction::ToViewer, Direction::Off, false);
        assert!(!to_viewer.allows(Flow::FromViewer, &ClientMsg::Clipboard(clip()).encode()));
        assert!(to_viewer.allows(Flow::FromHost, &HostMsg::Clipboard(clip()).encode()));
        let off = p(true, Direction::Off, Direction::Off, false);
        assert!(!off.allows(Flow::FromHost, &HostMsg::ClipboardCaps { formats: 3, max_bytes: 100 }.encode()));
        assert!(to_viewer.allows(Flow::FromHost, &HostMsg::ClipboardCaps { formats: 3, max_bytes: 100 }.encode()));
    }

    #[test]
    fn file_directions_follow_the_transfer_id() {
        let to_host = p(true, Direction::Off, Direction::ToHost, false);
        let viewer_id = 7;
        let host_id = FILE_HOST_ID_BIT | 7;
        let c = |m: FileMsg| ClientMsg::File(m).encode();
        let h = |m: FileMsg| HostMsg::File(m).encode();
        // The viewer's own transfer: its offer/chunks go out, the host's answer/acks come back.
        assert!(to_host.allows(Flow::FromViewer, &c(offer(viewer_id))));
        assert!(to_host.allows(Flow::FromViewer, &c(FileMsg::Chunk { id: viewer_id, index: 0, offset: 0, data: vec![1] })));
        assert!(to_host.allows(Flow::FromHost, &h(FileMsg::Answer { id: viewer_id, status: 0, detail: String::new() })));
        assert!(to_host.allows(Flow::FromHost, &h(FileMsg::Ack { id: viewer_id, bytes: 1 })));
        assert!(to_host.allows(Flow::FromHost, &h(FileMsg::Done { id: viewer_id, files: 1 })));
        // A host transfer is refused in both directions...
        assert!(!to_host.allows(Flow::FromHost, &h(offer(host_id))));
        assert!(!to_host.allows(Flow::FromHost, &h(FileMsg::Chunk { id: host_id, index: 0, offset: 0, data: vec![1] })));
        assert!(!to_host.allows(Flow::FromViewer, &c(FileMsg::Answer { id: host_id, status: 0, detail: String::new() })));
        assert!(!to_host.allows(Flow::FromViewer, &c(FileMsg::Pull)));
        // ...except a decline or a cancel.
        assert!(to_host.allows(Flow::FromViewer, &c(FileMsg::Answer { id: host_id, status: 1, detail: "no".into() })));
        assert!(to_host.allows(Flow::FromViewer, &c(FileMsg::Cancel { id: host_id, reason: 7, detail: String::new() })));
        // A modified host offering with a viewer-range id is still judged by the id.
        let to_viewer = p(true, Direction::Off, Direction::ToViewer, false);
        assert!(!to_viewer.allows(Flow::FromHost, &h(offer(viewer_id))));
        assert!(to_viewer.allows(Flow::FromHost, &h(offer(host_id))));
        assert!(to_viewer.allows(Flow::FromViewer, &c(FileMsg::Pull)));
        assert!(to_viewer.allows(Flow::FromHost, &h(FileMsg::PullResult { status: 0, detail: String::new() })));
        assert!(to_host.allows(Flow::FromHost, &h(FileMsg::PullResult { status: 11, detail: String::new() })));
        assert!(!to_host.allows(Flow::FromHost, &h(FileMsg::PullResult { status: 0, detail: String::new() })));
        // Off: not even FileCaps; truncated messages are refused.
        let off = p(true, Direction::Off, Direction::Off, false);
        assert!(!off.allows(Flow::FromHost, &h(FileMsg::Caps { flags: 3, max_total_bytes: 1, max_files: 1 })));
        assert!(!to_host.allows(Flow::FromViewer, &[MSG_FILE_CHUNK, 1, 0]));
        assert!(!to_host.allows(Flow::FromViewer, &[]));
    }

    #[test]
    fn audio_and_caps() {
        let no_audio = p(true, Direction::Both, Direction::Both, false);
        assert!(!no_audio.allows(Flow::FromHost, &[MSG_AUDIO_FRAME, 0, 0]));
        assert!(!no_audio.allows(Flow::FromHost, &[MSG_AUDIO_CONFIG]));
        assert!(no_audio.allows(Flow::FromViewer, &ClientMsg::AudioEnable { enabled: false }.encode()));
        assert!(!no_audio.allows(Flow::FromViewer, &ClientMsg::AudioEnable { enabled: true }.encode()), "audio: false → no AudioEnable(true)");
        assert!(!no_audio.allows(Flow::FromViewer, &[MSG_AUDIO_ENABLE]), "truncated");
        let with_audio = p(false, Direction::Off, Direction::Off, true);
        assert!(with_audio.allows(Flow::FromViewer, &ClientMsg::AudioEnable { enabled: true }.encode()));
        let all = CAP_HEVC_420 | CAP_CLIPBOARD | CAP_FILES | CAP_AUDIO_PCM | CAP_DISPLAYS;
        assert_eq!(no_audio.filter_caps(all), all & !CAP_AUDIO_PCM);
        assert_eq!(Permissions::default().filter_caps(all), CAP_HEVC_420 | CAP_DISPLAYS);
        // View only with to_viewer clipboard keeps the clipboard cap (host → viewer still allowed).
        assert_eq!(p(false, Direction::ToHost, Direction::Both, true).filter_caps(all), all & !CAP_CLIPBOARD);
        assert_eq!(
            p(false, Direction::Both, Direction::ToHost, true).describe(),
            "view only; clipboard from this computer only; file transfer off; sound on"
        );
        assert_eq!(p(true, Direction::Both, Direction::ToHost, false).describe(), "can use the keyboard and mouse; clipboard both ways; file transfer to this computer only; sound off");
    }
}
