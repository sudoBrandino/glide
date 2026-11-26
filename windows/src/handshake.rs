//! Glide v2 handshake framing and payloads (docs/PROTOCOL.md §1): version preambles, the Noise XX
//! messages with Glide's payloads, the pairing commitment and the Short Authentication String.
//!
//! Sans-IO: `ViewerHandshake` (initiator, used by `net`) and `HostHandshake` (responder, used by
//! tests, the transcript generator and the loopback fake host) only turn bytes into bytes.
//! Platform independent.

use crate::noise::{public_key, CipherState, HandshakeXX, NoiseError};
use sha2::{Digest, Sha256};
use x25519_dalek::StaticSecret;

pub const MAGIC_V2: &[u8; 4] = b"GLD2";
/// v1 (password) protocol magic: only recognized to give a clear error.
pub const MAGIC_V1: &[u8; 4] = b"GLD1";
pub const VERSION: u16 = 2;
pub const CLIENT_PREAMBLE_LEN: usize = 24;
pub const HOST_PREAMBLE_LEN: usize = 8;
/// Upper bound for one framed handshake message (DoS bound; real ones are < 400 bytes).
pub const MAX_HANDSHAKE_MSG: usize = 1024;
/// v1 sizes, for answering a v1 peer with an understandable error.
pub const V1_CLIENT_HS_LEN: usize = 54;
pub const V1_HOST_HS_LEN: usize = 70;

// HostPreamble.status
pub const ST_OK: u16 = 0;
pub const ST_UNSUPPORTED_VERSION: u16 = 1;
pub const ST_PAUSED: u16 = 2;
pub const ST_RATE_LIMITED: u16 = 3;

/// msg2 flags: the host's pairing window is open.
pub const HOST_FLAG_PAIRING_OPEN: u8 = 1;
/// msg3 flags: the viewer asks to pair (it has no pinned key for this host, or the host said it
/// no longer knows this viewer).
pub const VIEWER_FLAG_PAIR_REQUEST: u8 = 1;

pub const COMMIT_LABEL: &[u8] = b"glide-v2 pair commit";
pub const SAS_LABEL: &[u8] = b"glide-v2 sas";
/// Longest viewer name sent in msg3 (bytes).
pub const MAX_NAME: usize = 255;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HsError {
    Noise(NoiseError),
    /// Peer is not speaking Glide v2 (bad magic); `v1` = it sent the v1 magic.
    BadMagic { v1: bool },
    /// HostPreamble status != 0.
    Status { version: u16, status: u16 },
    /// Malformed payload / framing.
    Malformed(&'static str),
    /// The host's version inside msg2 doesn't match the preamble (tampering).
    VersionMismatch,
}

impl std::fmt::Display for HsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HsError::Noise(e) => write!(f, "{e}"),
            HsError::BadMagic { v1: true } => write!(f, "peer speaks Glide protocol v1"),
            HsError::BadMagic { v1: false } => write!(f, "peer is not a Glide host"),
            HsError::Status { version, status } => write!(f, "host refused the handshake (status {status}, version {version})"),
            HsError::Malformed(s) => write!(f, "malformed handshake: {s}"),
            HsError::VersionMismatch => write!(f, "handshake version mismatch"),
        }
    }
}

impl std::error::Error for HsError {}

impl From<NoiseError> for HsError {
    fn from(e: NoiseError) -> Self {
        HsError::Noise(e)
    }
}

pub fn client_preamble() -> [u8; CLIENT_PREAMBLE_LEN] {
    let mut p = [0u8; CLIENT_PREAMBLE_LEN];
    p[..4].copy_from_slice(MAGIC_V2);
    p[4..6].copy_from_slice(&VERSION.to_le_bytes()); // max version
    p[6..8].copy_from_slice(&VERSION.to_le_bytes()); // min version
    p
}

pub fn host_preamble(version: u16, status: u16) -> [u8; HOST_PREAMBLE_LEN] {
    let mut p = [0u8; HOST_PREAMBLE_LEN];
    p[..4].copy_from_slice(MAGIC_V2);
    p[4..6].copy_from_slice(&version.to_le_bytes());
    p[6..8].copy_from_slice(&status.to_le_bytes());
    p
}

/// Parse a HostPreamble. Ok(version) only for status 0.
pub fn parse_host_preamble(p: &[u8; HOST_PREAMBLE_LEN]) -> Result<u16, HsError> {
    if &p[..4] != MAGIC_V2 {
        return Err(HsError::BadMagic { v1: &p[..4] == MAGIC_V1 });
    }
    let version = u16::from_le_bytes([p[4], p[5]]);
    let status = u16::from_le_bytes([p[6], p[7]]);
    if status != ST_OK {
        return Err(HsError::Status { version, status });
    }
    if version != VERSION {
        return Err(HsError::Status { version, status: ST_UNSUPPORTED_VERSION });
    }
    Ok(version)
}

/// Host side: parse a ClientPreamble; returns (max, min) versions.
pub fn parse_client_preamble(p: &[u8]) -> Result<(u16, u16), HsError> {
    if p.len() < CLIENT_PREAMBLE_LEN {
        return Err(HsError::Malformed("short preamble"));
    }
    if &p[..4] != MAGIC_V2 {
        return Err(HsError::BadMagic { v1: &p[..4] == MAGIC_V1 });
    }
    Ok((u16::from_le_bytes([p[4], p[5]]), u16::from_le_bytes([p[6], p[7]])))
}

/// `u16 length || message` (handshake messages only).
pub fn frame(msg: &[u8]) -> Vec<u8> {
    assert!(msg.len() <= MAX_HANDSHAKE_MSG);
    let mut v = Vec::with_capacity(2 + msg.len());
    v.extend_from_slice(&(msg.len() as u16).to_le_bytes());
    v.extend_from_slice(msg);
    v
}

pub fn commitment(n_h: &[u8; 32]) -> [u8; 32] {
    let mut d = Sha256::new();
    d.update(COMMIT_LABEL);
    d.update(n_h);
    d.finalize().into()
}

/// The 6-digit Short Authentication String both sides show while pairing.
pub fn sas_code(h: &[u8; 32], n_v: &[u8; 32], n_h: &[u8; 32]) -> u32 {
    let mut d = Sha256::new();
    d.update(SAS_LABEL);
    d.update(h);
    d.update(n_v);
    d.update(n_h);
    let x: [u8; 32] = d.finalize().into();
    u32::from_be_bytes([x[0], x[1], x[2], x[3]]) % 1_000_000
}

/// "123 456".
pub fn sas_text(code: u32) -> String {
    format!("{:03} {:03}", code / 1000, code % 1000)
}

/// Short display fingerprint of a public key: first 8 bytes of SHA-256, "aaaa bbbb cccc dddd".
pub fn fingerprint(public: &[u8; 32]) -> String {
    let d: [u8; 32] = Sha256::digest(public).into();
    let h = crate::util::hex(&d[..8]);
    (0..4).map(|i| &h[i * 4..i * 4 + 4]).collect::<Vec<_>>().join(" ")
}

pub fn random32() -> [u8; 32] {
    let mut b = [0u8; 32];
    getrandom::fill(&mut b).expect("OS random number generator unavailable");
    b
}

/// msg2 payload: `u16 version`, `u8 flags`, `32 commitment`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostInfo {
    pub version: u16,
    pub flags: u8,
    pub commitment: [u8; 32],
}

impl HostInfo {
    pub fn encode(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(35);
        v.extend_from_slice(&self.version.to_le_bytes());
        v.push(self.flags);
        v.extend_from_slice(&self.commitment);
        v
    }
    pub fn decode(p: &[u8]) -> Result<HostInfo, HsError> {
        if p.len() < 35 {
            return Err(HsError::Malformed("short msg2 payload"));
        }
        Ok(HostInfo { version: u16::from_le_bytes([p[0], p[1]]), flags: p[2], commitment: p[3..35].try_into().unwrap() })
    }
    pub fn pairing_open(&self) -> bool {
        self.flags & HOST_FLAG_PAIRING_OPEN != 0
    }
}

/// msg3 payload: `u8 flags`, `32 viewer nonce`, `str name`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ViewerInfo {
    pub flags: u8,
    pub nonce: [u8; 32],
    pub name: String,
}

impl ViewerInfo {
    pub fn encode(&self) -> Vec<u8> {
        let mut name = self.name.as_bytes();
        if name.len() > MAX_NAME {
            let mut n = MAX_NAME;
            while !self.name.is_char_boundary(n) {
                n -= 1;
            }
            name = &name[..n];
        }
        let mut v = Vec::with_capacity(35 + name.len());
        v.push(self.flags);
        v.extend_from_slice(&self.nonce);
        v.extend_from_slice(&(name.len() as u16).to_le_bytes());
        v.extend_from_slice(name);
        v
    }
    pub fn decode(p: &[u8]) -> Result<ViewerInfo, HsError> {
        if p.len() < 35 {
            return Err(HsError::Malformed("short msg3 payload"));
        }
        let n = u16::from_le_bytes([p[33], p[34]]) as usize;
        if p.len() < 35 + n {
            return Err(HsError::Malformed("truncated viewer name"));
        }
        Ok(ViewerInfo { flags: p[0], nonce: p[1..33].try_into().unwrap(), name: String::from_utf8_lossy(&p[35..35 + n]).into_owned() })
    }
    pub fn pair_request(&self) -> bool {
        self.flags & VIEWER_FLAG_PAIR_REQUEST != 0
    }
}

/// Transport state after a completed handshake.
pub struct Established {
    /// Our sending / receiving transport ciphers (Noise Split()).
    pub send: CipherState,
    pub recv: CipherState,
    pub handshake_hash: [u8; 32],
    pub remote_static: [u8; 32],
}

impl Established {
    pub fn send_key(&self) -> [u8; 32] {
        self.send.key().unwrap()
    }
    pub fn recv_key(&self) -> [u8; 32] {
        self.recv.key().unwrap()
    }
}

/// Viewer (initiator) side.
pub struct ViewerHandshake {
    hs: HandshakeXX,
    preamble: [u8; CLIENT_PREAMBLE_LEN],
    nonce: [u8; 32],
    name: String,
    host: Option<HostInfo>,
}

impl ViewerHandshake {
    /// `ephemeral` / `nonce`: fixed values for vectors; None = random.
    pub fn new(identity: StaticSecret, name: &str, ephemeral: Option<StaticSecret>, nonce: Option<[u8; 32]>) -> Self {
        let preamble = client_preamble();
        ViewerHandshake {
            hs: HandshakeXX::new(true, identity, &preamble, ephemeral),
            preamble,
            nonce: nonce.unwrap_or_else(random32),
            name: name.to_string(),
            host: None,
        }
    }

    /// ClientPreamble || frame(msg1).
    pub fn first_flight(&mut self) -> Vec<u8> {
        let m1 = self.hs.write_message(&[]).expect("msg1");
        let mut v = self.preamble.to_vec();
        v.extend(frame(&m1));
        v
    }

    /// Process msg2 (unframed). Returns the host's static key and info.
    pub fn read_msg2(&mut self, msg2: &[u8], preamble_version: u16) -> Result<([u8; 32], HostInfo), HsError> {
        let p = self.hs.read_message(msg2)?;
        let info = HostInfo::decode(&p)?;
        if info.version != preamble_version {
            return Err(HsError::VersionMismatch);
        }
        self.host = Some(info.clone());
        Ok((self.hs.remote_static().unwrap(), info))
    }

    /// frame(msg3).
    pub fn write_msg3(&mut self, flags: u8) -> Vec<u8> {
        let p = ViewerInfo { flags, nonce: self.nonce, name: self.name.clone() }.encode();
        frame(&self.hs.write_message(&p).expect("msg3"))
    }

    pub fn nonce(&self) -> [u8; 32] {
        self.nonce
    }
    pub fn host_commitment(&self) -> Option<[u8; 32]> {
        self.host.as_ref().map(|h| h.commitment)
    }

    pub fn finish(self) -> Established {
        assert!(self.hs.is_finished());
        let (send, recv) = self.hs.split();
        Established { send, recv, handshake_hash: self.hs.handshake_hash(), remote_static: self.hs.remote_static().unwrap() }
    }
}

/// Host (responder) side. The real host is Swift; this one serves tests, vectors and tooling.
pub struct HostHandshake {
    hs: HandshakeXX,
    pub nonce: [u8; 32],
    pub viewer: Option<ViewerInfo>,
}

impl HostHandshake {
    /// Reads ClientPreamble + msg1 (unframed). Returns the host after msg1.
    pub fn read_first(
        identity: StaticSecret,
        preamble: &[u8],
        msg1: &[u8],
        ephemeral: Option<StaticSecret>,
        nonce: Option<[u8; 32]>,
    ) -> Result<HostHandshake, HsError> {
        let (max, min) = parse_client_preamble(preamble)?;
        if !(min..=max).contains(&VERSION) {
            return Err(HsError::Status { version: VERSION, status: ST_UNSUPPORTED_VERSION });
        }
        let mut hs = HandshakeXX::new(false, identity, &preamble[..CLIENT_PREAMBLE_LEN], ephemeral);
        let p = hs.read_message(msg1)?;
        if !p.is_empty() {
            return Err(HsError::Malformed("msg1 payload must be empty"));
        }
        Ok(HostHandshake { hs, nonce: nonce.unwrap_or_else(random32), viewer: None })
    }

    /// HostPreamble || frame(msg2).
    pub fn write_msg2(&mut self, flags: u8) -> Vec<u8> {
        let p = HostInfo { version: VERSION, flags, commitment: commitment(&self.nonce) }.encode();
        let m2 = self.hs.write_message(&p).expect("msg2");
        let mut v = host_preamble(VERSION, ST_OK).to_vec();
        v.extend(frame(&m2));
        v
    }

    pub fn read_msg3(&mut self, msg3: &[u8]) -> Result<([u8; 32], ViewerInfo), HsError> {
        let p = self.hs.read_message(msg3)?;
        let v = ViewerInfo::decode(&p)?;
        self.viewer = Some(v.clone());
        Ok((self.hs.remote_static().unwrap(), v))
    }

    pub fn finish(self) -> Established {
        assert!(self.hs.is_finished());
        let (send, recv) = self.hs.split();
        Established { send, recv, handshake_hash: self.hs.handshake_hash(), remote_static: self.hs.remote_static().unwrap() }
    }
}

pub fn identity_public(s: &StaticSecret) -> [u8; 32] {
    public_key(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{Opener, Sealer};
    use crate::util::{hex, unhex};
    use serde_json::{json, Value};

    fn sk(h: &str) -> StaticSecret {
        StaticSecret::from(<[u8; 32]>::try_from(unhex(h)).unwrap())
    }
    fn b32(h: &str) -> [u8; 32] {
        unhex(h).try_into().unwrap()
    }

    fn client_hello(name: &str) -> Vec<u8> {
        crate::protocol::ClientMsg::ClientHello { version: 2, codec_caps: 0b111, view_w: 3840, view_h: 2160, mode: 0, max_fps: 60, client_name: name.into() }
            .encode()
    }
    fn server_hello(name: &str) -> Vec<u8> {
        use crate::protocol::{Codec, HostMsg, VideoConfig};
        HostMsg::ServerHello {
            version: 2,
            host_name: name.into(),
            config: VideoConfig { width: 2560, height: 1440, codec: Codec::Hevc, chroma: 0, color: 0, scale: 2.0 },
        }
        .encode()
    }
    const MOUSE: [u8; 9] = [0x10, 0, 0, 0x80, 0x3e, 0, 0, 0x40, 0x3f];

    /// Runs one session from transcript inputs with both Rust engines; returns derived fields.
    fn run_session(viewer_static: &str, host_static: &str, inp: &Value) -> Value {
        let g = |k: &str| inp[k].as_str().unwrap().to_string();
        let pairing = g("kind") == "pairing";
        let mut v = ViewerHandshake::new(sk(viewer_static), &g("viewer_name"), Some(sk(&g("viewer_ephemeral"))), Some(b32(&g("viewer_nonce"))));
        let f1 = v.first_flight();
        let msg1 = f1[CLIENT_PREAMBLE_LEN + 2..].to_vec();
        let mut h = HostHandshake::read_first(sk(host_static), &f1[..CLIENT_PREAMBLE_LEN], &msg1, Some(sk(&g("host_ephemeral"))), Some(b32(&g("host_nonce"))))
            .unwrap();
        let f2 = h.write_msg2(inp["host_flags"].as_u64().unwrap() as u8);
        let msg2 = f2[HOST_PREAMBLE_LEN + 2..].to_vec();
        let ver = parse_host_preamble(&f2[..HOST_PREAMBLE_LEN].try_into().unwrap()).unwrap();
        let (hk, info) = v.read_msg2(&msg2, ver).unwrap();
        assert_eq!(hk, public_key(&sk(host_static)));
        let f3 = v.write_msg3(inp["viewer_flags"].as_u64().unwrap() as u8);
        let msg3 = f3[2..].to_vec();
        let (vk, vinfo) = h.read_msg3(&msg3).unwrap();
        assert_eq!(vk, public_key(&sk(viewer_static)));
        assert_eq!(vinfo.name, g("viewer_name"));
        let n_v = v.nonce();
        let ve = v.finish();
        let he = h.finish();
        assert_eq!(ve.handshake_hash, he.handshake_hash);
        assert_eq!((ve.send_key(), ve.recv_key()), (he.recv_key(), he.send_key()));
        let n_h = b32(&g("host_nonce"));
        assert_eq!(info.commitment, commitment(&n_h));

        let mut c2s = Sealer::new(&ve.send_key());
        let mut s2c = Sealer::new(&he.send_key());
        let mut c2s_open = Opener::new(&he.recv_key());
        let mut s2c_open = Opener::new(&ve.recv_key());
        let mut recs = vec![];
        let mut rec = |dir: &str, pt: Vec<u8>| -> Vec<u8> {
            let r = if dir == "c2s" { c2s.seal(&pt) } else { s2c.seal(&pt) };
            let back = if dir == "c2s" { c2s_open.open(&r[4..]).unwrap() } else { s2c_open.open(&r[4..]).unwrap() };
            assert_eq!(back, pt);
            recs.push(json!({"dir": dir, "plaintext": hex(&pt), "record": hex(&r)}));
            r
        };
        let mut flights: Vec<(&str, Vec<u8>)> = vec![("viewer", f1.clone()), ("host", f2.clone())];
        if pairing {
            flights.push(("viewer", f3.clone()));
            let mut reveal = vec![0x09];
            reveal.extend_from_slice(&n_h);
            flights.push(("host", rec("s2c", reveal)));
            flights.push(("viewer", rec("c2s", vec![0x0A, 1])));
            flights.push(("host", rec("s2c", vec![0x08, 0])));
            flights.push(("viewer", rec("c2s", client_hello(&g("viewer_name")))));
            flights.push(("host", rec("s2c", server_hello(&g("host_name")))));
        } else {
            let mut f = f3.clone();
            f.extend(rec("c2s", client_hello(&g("viewer_name"))));
            flights.push(("viewer", f));
            flights.push(("host", rec("s2c", server_hello(&g("host_name")))));
            flights.push(("viewer", rec("c2s", MOUSE.to_vec())));
        }
        let mut out = inp.clone();
        let o = out.as_object_mut().unwrap();
        let mut set = |k: &str, v: Value| {
            o.insert(k.into(), v);
        };
        set("client_preamble", json!(hex(&f1[..CLIENT_PREAMBLE_LEN])));
        set("msg1", json!(hex(&msg1)));
        set("host_preamble", json!(hex(&f2[..HOST_PREAMBLE_LEN])));
        set("msg2_payload", json!(hex(&info.encode())));
        set("msg2", json!(hex(&msg2)));
        set("msg3_payload", json!(hex(&vinfo.encode())));
        set("msg3", json!(hex(&msg3)));
        set("handshake_hash", json!(hex(&ve.handshake_hash)));
        set("c2s_key", json!(hex(&ve.send_key())));
        set("s2c_key", json!(hex(&ve.recv_key())));
        set("commitment", json!(hex(&commitment(&n_h))));
        set("sas", json!(sas_text(sas_code(&ve.handshake_hash, &n_v, &n_h))));
        set("records", json!(recs));
        set("flights", json!(flights.iter().map(|(f, b)| json!({"from": f, "bytes": hex(b)})).collect::<Vec<_>>()));
        out
    }

    const INPUT_KEYS: [&str; 9] =
        ["kind", "viewer_name", "host_name", "viewer_flags", "host_flags", "viewer_ephemeral", "host_ephemeral", "viewer_nonce", "host_nonce"];

    fn regenerate(doc: &Value) -> Vec<Value> {
        let vs = doc["viewer_static"].as_str().unwrap();
        let hs = doc["host_static"].as_str().unwrap();
        doc["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                let inp: serde_json::Map<String, Value> = INPUT_KEYS.iter().map(|k| (k.to_string(), s[*k].clone())).collect();
                run_session(vs, hs, &Value::Object(inp))
            })
            .collect()
    }

    fn check_doc(doc: &Value) {
        let vs = doc["viewer_static"].as_str().unwrap();
        let hs = doc["host_static"].as_str().unwrap();
        assert_eq!(doc["viewer_static_pub"], hex(&public_key(&sk(vs))));
        assert_eq!(doc["host_static_pub"], hex(&public_key(&sk(hs))));
        assert_eq!(doc["viewer_fingerprint"], fingerprint(&public_key(&sk(vs))));
        assert_eq!(doc["host_fingerprint"], fingerprint(&public_key(&sk(hs))));
        let again = regenerate(doc);
        let sessions = doc["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), again.len());
        for (i, (a, b)) in sessions.iter().zip(&again).enumerate() {
            for (k, v) in b.as_object().unwrap() {
                assert_eq!(&a[k], v, "sessions[{i}].{k}");
            }
        }
    }

    /// The Python reference transcript (tools/gen_vectors.py) is reproduced byte for byte.
    #[test]
    fn python_reference_transcript() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/test-vectors.json");
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        check_doc(&doc);
    }

    fn rust_doc() -> Value {
        let seq = |start: u8| -> String { hex(&(0..32u8).map(|i| start.wrapping_add(i.wrapping_mul(3))).collect::<Vec<_>>()) };
        let sessions = vec![
            json!({"kind": "pairing", "viewer_name": "rust-viewer ✓", "host_name": "Rust Host",
                   "viewer_flags": VIEWER_FLAG_PAIR_REQUEST, "host_flags": HOST_FLAG_PAIRING_OPEN,
                   "viewer_ephemeral": seq(0x31), "host_ephemeral": seq(0x52), "viewer_nonce": seq(0x73), "host_nonce": seq(0x94)}),
            json!({"kind": "pinned", "viewer_name": "rust-viewer ✓", "host_name": "Rust Host",
                   "viewer_flags": 0, "host_flags": HOST_FLAG_PAIRING_OPEN,
                   "viewer_ephemeral": seq(0xB5), "host_ephemeral": seq(0xD6), "viewer_nonce": seq(0xF7), "host_nonce": seq(0x18)}),
        ];
        let (vs, hs) = (seq(0x07), seq(0x2a));
        let base = json!({"viewer_static": vs, "host_static": hs, "sessions": sessions});
        let derived = regenerate(&base);
        json!({
            "_comment": "Glide v2 handshake transcripts (docs/PROTOCOL.md §1-2). Inputs: the static and ephemeral private keys, nonces, names and flags; everything else is derived. 'flights' are the exact bytes each side writes, in order. Generated by the Rust viewer's implementation (windows/src/handshake.rs, `GLIDE_REGEN_VECTORS=1 cargo test rust_transcript`).",
            "protocol": "Noise_XX_25519_ChaChaPoly_SHA256",
            "viewer_static": vs, "viewer_static_pub": hex(&public_key(&sk(&vs))),
            "host_static": hs, "host_static_pub": hex(&public_key(&sk(&hs))),
            "viewer_fingerprint": fingerprint(&public_key(&sk(&vs))),
            "host_fingerprint": fingerprint(&public_key(&sk(&hs))),
            "sessions": derived,
        })
    }

    /// docs/test-vectors-rust.json is what this implementation generates (Swift's glide-selftest
    /// and `tools/gen_vectors.py --check` replay it). Regenerate with GLIDE_REGEN_VECTORS=1.
    #[test]
    fn rust_transcript() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/test-vectors-rust.json");
        let doc = rust_doc();
        let text = serde_json::to_string_pretty(&doc).unwrap() + "\n";
        if std::env::var("GLIDE_REGEN_VECTORS").as_deref() == Ok("1") {
            std::fs::write(path, &text).unwrap();
        }
        let committed = std::fs::read_to_string(path).expect("docs/test-vectors-rust.json (GLIDE_REGEN_VECTORS=1 cargo test rust_transcript)");
        let committed: Value = serde_json::from_str(&committed).unwrap();
        assert_eq!(committed, doc, "docs/test-vectors-rust.json is stale: GLIDE_REGEN_VECTORS=1 cargo test rust_transcript");
        check_doc(&committed);
    }

    #[test]
    fn preambles_and_payloads() {
        let p = client_preamble();
        assert_eq!(hex(&p), "474c443202000200".to_string() + &"00".repeat(16));
        assert_eq!(parse_client_preamble(&p), Ok((2, 2)));
        // First flight is long enough that a v1 host (reads exactly 54 bytes) fails fast on the magic.
        let mut v = ViewerHandshake::new(StaticSecret::random_from_rng(&mut crate::crypto::os_rng()), "x", None, None);
        assert!(v.first_flight().len() >= V1_CLIENT_HS_LEN);
        assert_eq!(parse_host_preamble(&host_preamble(2, ST_OK)), Ok(2));
        assert_eq!(parse_host_preamble(&host_preamble(2, ST_RATE_LIMITED)), Err(HsError::Status { version: 2, status: 3 }));
        assert_eq!(parse_host_preamble(&host_preamble(3, ST_OK)), Err(HsError::Status { version: 3, status: 1 }));
        let mut v1 = [0u8; 8];
        v1[..4].copy_from_slice(MAGIC_V1);
        assert_eq!(parse_host_preamble(&v1), Err(HsError::BadMagic { v1: true }));
        assert_eq!(parse_client_preamble(b"GLD1\x01\x00aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), Err(HsError::BadMagic { v1: true }));
        // Payload codecs
        let vi = ViewerInfo { flags: 1, nonce: [7; 32], name: "é".repeat(200) };
        let enc = vi.encode();
        let back = ViewerInfo::decode(&enc).unwrap();
        assert!(back.name.len() <= MAX_NAME && back.name.chars().all(|c| c == 'é'), "truncated on a char boundary");
        assert!(ViewerInfo::decode(&enc[..40]).is_err());
        assert!(HostInfo::decode(&[0; 34]).is_err());
        assert_eq!(sas_text(7), "000 007");
        assert_eq!(sas_text(123456), "123 456");
    }

    #[test]
    fn version_mismatch_inside_msg2_is_detected() {
        let mut v = ViewerHandshake::new(StaticSecret::random_from_rng(&mut crate::crypto::os_rng()), "x", None, None);
        let f1 = v.first_flight();
        let mut h = HostHandshake::read_first(StaticSecret::random_from_rng(&mut crate::crypto::os_rng()), &f1[..24], &f1[26..], None, None).unwrap();
        let f2 = h.write_msg2(0);
        // A tampered preamble claiming another version can't be matched by msg2's authenticated copy.
        assert_eq!(v.read_msg2(&f2[10..], 3).err(), Some(HsError::VersionMismatch));
    }
}
