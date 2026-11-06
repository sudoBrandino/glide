//! Test-only loopback host: the host side of the v2 handshake, pairing and ServerHello over a
//! real TCP stream (docs/PROTOCOL.md §1–2), with knobs for every rejection path.

use crate::crypto::{Opener, Sealer};
use crate::handshake::*;
use crate::identity::Identity;
use crate::protocol::{ClientMsg, Codec, HostMsg, VideoConfig};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

#[derive(Clone)]
pub struct HostCfg {
    pub identity: Identity,
    pub paired: Vec<[u8; 32]>,
    pub pairing_open: bool,
    /// The Mac user's answer to the pairing code.
    pub confirm: bool,
    /// Wait this long before giving the host-side answer.
    pub confirm_delay: Duration,
    /// HostPreamble status to answer with (0 = proceed).
    pub status: u16,
    /// Behave like a v1 host: read 54 bytes, then close.
    pub v1: bool,
    /// Send AuthResult(code) right after PairReveal (host declines/times out before the viewer answers).
    pub abort_after_reveal: Option<u8>,
}

impl HostCfg {
    pub fn new(identity: Identity) -> HostCfg {
        HostCfg {
            identity,
            paired: vec![],
            pairing_open: false,
            confirm: true,
            confirm_delay: Duration::ZERO,
            status: ST_OK,
            v1: false,
            abort_after_reveal: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Sent ServerHello to a paired viewer (`paired_now` = this connection paired it).
    Streaming { viewer_key: [u8; 32], name: String, paired_now: bool },
    Rejected(u8),
    /// Pairing ended because the viewer said no.
    ViewerDeclined,
    Refused(u16),
    Closed(String),
}

fn frame_in(s: &mut TcpStream) -> std::io::Result<Vec<u8>> {
    let mut l = [0u8; 2];
    s.read_exact(&mut l)?;
    let mut m = vec![0u8; u16::from_le_bytes(l) as usize];
    s.read_exact(&mut m)?;
    Ok(m)
}

pub fn serve(mut s: TcpStream, cfg: &HostCfg) -> Outcome {
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    if cfg.v1 {
        let mut b = [0u8; V1_CLIENT_HS_LEN];
        let _ = s.read_exact(&mut b);
        return Outcome::Closed("v1 host: bad magic".into());
    }
    let mut pre = [0u8; CLIENT_PREAMBLE_LEN];
    if let Err(e) = s.read_exact(&mut pre) {
        return Outcome::Closed(e.to_string());
    }
    let msg1 = match frame_in(&mut s) {
        Ok(m) => m,
        Err(e) => return Outcome::Closed(e.to_string()),
    };
    if cfg.status != ST_OK {
        let _ = s.write_all(&host_preamble(VERSION, cfg.status));
        return Outcome::Refused(cfg.status);
    }
    let mut h = match HostHandshake::read_first(cfg.identity.secret(), &pre, &msg1, None, None) {
        Ok(h) => h,
        Err(e) => return Outcome::Closed(e.to_string()),
    };
    let n_h = h.nonce;
    s.write_all(&h.write_msg2(if cfg.pairing_open { HOST_FLAG_PAIRING_OPEN } else { 0 })).unwrap();
    let msg3 = match frame_in(&mut s) {
        Ok(m) => m,
        Err(e) => return Outcome::Closed(format!("viewer left before msg3: {e}")),
    };
    let (vkey, info) = match h.read_msg3(&msg3) {
        Ok(x) => x,
        Err(e) => return Outcome::Closed(e.to_string()),
    };
    let est = h.finish();
    let mut seal = Sealer::new(&est.send_key());
    let mut open = Opener::new(&est.recv_key());
    let mut buf = Vec::new();
    let mut send = |s: &mut TcpStream, m: HostMsg| {
        let _ = s.write_all(&seal.seal(&m.encode()));
    };
    let reject = |s: &mut TcpStream, send: &mut dyn FnMut(&mut TcpStream, HostMsg), code: u8| {
        send(s, HostMsg::AuthResult { code });
        let _ = s.shutdown(std::net::Shutdown::Both);
        Outcome::Rejected(code)
    };
    let mut paired_now = false;
    if info.pair_request() {
        if !cfg.pairing_open {
            return reject(&mut s, &mut send, crate::protocol::AUTH_PAIRING_CLOSED);
        }
        send(&mut s, HostMsg::PairReveal { nonce: n_h });
        if let Some(code) = cfg.abort_after_reveal {
            return reject(&mut s, &mut send, code);
        }
        let _ = s.set_read_timeout(Some(Duration::from_secs(30)));
        let viewer_ok = match open.read_record(&mut s, &mut buf).map(|pt| ClientMsg::decode(&pt)) {
            Ok(Ok(ClientMsg::PairConfirm { matched })) => matched,
            other => return Outcome::Closed(format!("expected PairConfirm: {:?}", other.map(|_| ()).err())),
        };
        if !viewer_ok {
            return Outcome::ViewerDeclined;
        }
        std::thread::sleep(cfg.confirm_delay);
        if !cfg.confirm {
            return reject(&mut s, &mut send, crate::protocol::AUTH_DECLINED);
        }
        send(&mut s, HostMsg::AuthResult { code: crate::protocol::AUTH_OK });
        paired_now = true;
    } else if !cfg.paired.contains(&vkey) {
        return reject(&mut s, &mut send, crate::protocol::AUTH_UNKNOWN_VIEWER);
    }
    match open.read_record(&mut s, &mut buf).map(|pt| ClientMsg::decode(&pt)) {
        Ok(Ok(ClientMsg::ClientHello { .. })) => {}
        other => return Outcome::Closed(format!("expected ClientHello: {:?}", other.map(|_| ()).err())),
    }
    let cfgv = VideoConfig { width: 64, height: 64, codec: Codec::Hevc, chroma: 0, color: 0, scale: 1.0 };
    send(&mut s, HostMsg::ServerHello { version: crate::protocol::PROTOCOL_VERSION, host_name: "fake".into(), config: cfgv });
    Outcome::Streaming { viewer_key: vkey, name: info.name, paired_now }
}
