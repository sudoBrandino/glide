//! Noise_XX_25519_ChaChaPoly_SHA256 (Noise Protocol Framework, revision 34), both roles.
//!
//! Hand-written on the primitives the viewer already uses (x25519-dalek, chacha20poly1305,
//! hkdf/sha2) so the MinGW and MSVC builds need no new crates. Checked against the official
//! vectors in docs/noise-vectors.json (cacophony, noise-c, snow) and against the Python and Swift
//! implementations through docs/test-vectors*.json. Platform independent.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use crate::crypto::os_rng;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

pub const PROTOCOL_NAME: &[u8] = b"Noise_XX_25519_ChaChaPoly_SHA256";
pub const DHLEN: usize = 32;
pub const HASHLEN: usize = 32;
pub const TAGLEN: usize = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NoiseError {
    /// AEAD authentication failed (tampered message, wrong key).
    Decrypt,
    /// Message too short for the pattern step.
    Short,
    /// write/read called out of turn.
    State,
    /// The peer sent a low-order (all-zero shared secret) public key.
    BadKey,
}

impl std::fmt::Display for NoiseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NoiseError::Decrypt => write!(f, "handshake message failed authentication"),
            NoiseError::Short => write!(f, "handshake message too short"),
            NoiseError::State => write!(f, "handshake message out of order"),
            NoiseError::BadKey => write!(f, "peer sent an invalid public key"),
        }
    }
}

impl std::error::Error for NoiseError {}

fn nonce(n: u64) -> [u8; 12] {
    let mut b = [0u8; 12];
    b[4..].copy_from_slice(&n.to_le_bytes());
    b
}

/// Noise HKDF with two outputs: RFC 5869 HKDF-SHA256 with salt = chaining key, empty info.
pub fn hkdf2(ck: &[u8; HASHLEN], ikm: &[u8]) -> ([u8; 32], [u8; 32]) {
    let hk = Hkdf::<Sha256>::new(Some(ck), ikm);
    let mut okm = [0u8; 64];
    hk.expand(&[], &mut okm).expect("64 bytes is a valid HKDF length");
    (okm[..32].try_into().unwrap(), okm[32..].try_into().unwrap())
}

/// A Noise CipherState. Transport records use these keys with Glide's own u32 framing
/// (crypto::Sealer/Opener: same nonce layout, empty AAD).
#[derive(Clone)]
pub struct CipherState {
    k: Option<[u8; 32]>,
    n: u64,
}

impl CipherState {
    fn empty() -> Self {
        CipherState { k: None, n: 0 }
    }
    pub fn key(&self) -> Option<[u8; 32]> {
        self.k
    }
    pub fn encrypt_with_ad(&mut self, ad: &[u8], pt: &[u8]) -> Vec<u8> {
        let Some(k) = self.k else { return pt.to_vec() };
        let c = ChaCha20Poly1305::new(&Key::from(k));
        let out = c.encrypt(&Nonce::from(nonce(self.n)), Payload { msg: pt, aad: ad }).expect("encrypt");
        self.n += 1;
        out
    }
    pub fn decrypt_with_ad(&mut self, ad: &[u8], ct: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let Some(k) = self.k else { return Ok(ct.to_vec()) };
        let c = ChaCha20Poly1305::new(&Key::from(k));
        let out = c.decrypt(&Nonce::from(nonce(self.n)), Payload { msg: ct, aad: ad }).map_err(|_| NoiseError::Decrypt)?;
        self.n += 1;
        Ok(out)
    }
}

struct SymmetricState {
    h: [u8; HASHLEN],
    ck: [u8; HASHLEN],
    cs: CipherState,
}

impl SymmetricState {
    fn new() -> Self {
        // Protocol name is exactly 32 bytes: h = name (no padding / hashing needed, but handle both).
        let mut h = [0u8; HASHLEN];
        if PROTOCOL_NAME.len() <= HASHLEN {
            h[..PROTOCOL_NAME.len()].copy_from_slice(PROTOCOL_NAME);
        } else {
            h = Sha256::digest(PROTOCOL_NAME).into();
        }
        SymmetricState { h, ck: h, cs: CipherState::empty() }
    }
    fn mix_key(&mut self, ikm: &[u8]) {
        let (ck, k) = hkdf2(&self.ck, ikm);
        self.ck = ck;
        self.cs = CipherState { k: Some(k), n: 0 };
    }
    fn mix_hash(&mut self, data: &[u8]) {
        let mut d = Sha256::new();
        d.update(self.h);
        d.update(data);
        self.h = d.finalize().into();
    }
    fn encrypt_and_hash(&mut self, pt: &[u8]) -> Vec<u8> {
        let h = self.h;
        let ct = self.cs.encrypt_with_ad(&h, pt);
        self.mix_hash(&ct);
        ct
    }
    fn decrypt_and_hash(&mut self, ct: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let h = self.h;
        let pt = self.cs.decrypt_with_ad(&h, ct)?;
        self.mix_hash(ct);
        Ok(pt)
    }
    fn split(&self) -> (CipherState, CipherState) {
        let (k1, k2) = hkdf2(&self.ck, &[]);
        (CipherState { k: Some(k1), n: 0 }, CipherState { k: Some(k2), n: 0 })
    }
}

fn dh(sk: &StaticSecret, pk: &[u8; 32]) -> Result<[u8; 32], NoiseError> {
    let ss = sk.diffie_hellman(&PublicKey::from(*pk));
    // A low-order peer key yields all zeros (Noise §9.1 allows either behavior; we reject).
    if !ss.was_contributory() {
        return Err(NoiseError::BadKey);
    }
    Ok(*ss.as_bytes())
}

/// XX handshake: `-> e`, `<- e, ee, s, es`, `-> s, se`.
pub struct HandshakeXX {
    initiator: bool,
    s: StaticSecret,
    e: Option<StaticSecret>,
    re: Option<[u8; 32]>,
    rs: Option<[u8; 32]>,
    ss: SymmetricState,
    step: u8,
}

impl HandshakeXX {
    /// `ephemeral`: fixed ephemeral key (tests/vectors); None = fresh random.
    pub fn new(initiator: bool, s: StaticSecret, prologue: &[u8], ephemeral: Option<StaticSecret>) -> Self {
        let mut ss = SymmetricState::new();
        ss.mix_hash(prologue);
        HandshakeXX { initiator, s, e: ephemeral, re: None, rs: None, ss, step: 0 }
    }

    fn ephemeral(&mut self) -> [u8; 32] {
        let e = self.e.get_or_insert_with(|| StaticSecret::random_from_rng(&mut os_rng()));
        *PublicKey::from(&*e).as_bytes()
    }

    pub fn write_message(&mut self, payload: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let mut out = Vec::with_capacity(96 + payload.len() + TAGLEN);
        match (self.initiator, self.step) {
            (true, 0) => {
                let e = self.ephemeral();
                self.ss.mix_hash(&e);
                out.extend_from_slice(&e);
            }
            (false, 1) => {
                let e = self.ephemeral();
                self.ss.mix_hash(&e);
                out.extend_from_slice(&e);
                let re = self.re.ok_or(NoiseError::State)?;
                let ee = dh(self.e.as_ref().unwrap(), &re)?;
                self.ss.mix_key(&ee);
                let spub = *PublicKey::from(&self.s).as_bytes();
                out.extend(self.ss.encrypt_and_hash(&spub));
                let es = dh(&self.s, &re)?;
                self.ss.mix_key(&es);
            }
            (true, 2) => {
                let spub = *PublicKey::from(&self.s).as_bytes();
                out.extend(self.ss.encrypt_and_hash(&spub));
                let re = self.re.ok_or(NoiseError::State)?;
                let se = dh(&self.s, &re)?;
                self.ss.mix_key(&se);
            }
            _ => return Err(NoiseError::State),
        }
        out.extend(self.ss.encrypt_and_hash(payload));
        self.step += 1;
        Ok(out)
    }

    pub fn read_message(&mut self, msg: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let rest: &[u8] = match (self.initiator, self.step) {
            (false, 0) => {
                if msg.len() < DHLEN {
                    return Err(NoiseError::Short);
                }
                let re: [u8; 32] = msg[..DHLEN].try_into().unwrap();
                self.ss.mix_hash(&re);
                self.re = Some(re);
                &msg[DHLEN..]
            }
            (true, 1) => {
                if msg.len() < DHLEN + DHLEN + 2 * TAGLEN {
                    return Err(NoiseError::Short);
                }
                let re: [u8; 32] = msg[..DHLEN].try_into().unwrap();
                self.ss.mix_hash(&re);
                self.re = Some(re);
                let ee = dh(self.e.as_ref().ok_or(NoiseError::State)?, &re)?;
                self.ss.mix_key(&ee);
                let rs: [u8; 32] = self.ss.decrypt_and_hash(&msg[DHLEN..DHLEN + DHLEN + TAGLEN])?.try_into().unwrap();
                self.rs = Some(rs);
                let es = dh(self.e.as_ref().unwrap(), &rs)?;
                self.ss.mix_key(&es);
                &msg[DHLEN + DHLEN + TAGLEN..]
            }
            (false, 2) => {
                if msg.len() < DHLEN + 2 * TAGLEN {
                    return Err(NoiseError::Short);
                }
                let rs: [u8; 32] = self.ss.decrypt_and_hash(&msg[..DHLEN + TAGLEN])?.try_into().unwrap();
                self.rs = Some(rs);
                let se = dh(self.e.as_ref().ok_or(NoiseError::State)?, &rs)?;
                self.ss.mix_key(&se);
                &msg[DHLEN + TAGLEN..]
            }
            _ => return Err(NoiseError::State),
        };
        let payload = self.ss.decrypt_and_hash(rest)?;
        self.step += 1;
        Ok(payload)
    }

    pub fn is_finished(&self) -> bool {
        self.step == 3
    }

    /// The peer's static public key (known after message 2 for the initiator, 3 for the responder).
    pub fn remote_static(&self) -> Option<[u8; 32]> {
        self.rs
    }

    pub fn handshake_hash(&self) -> [u8; 32] {
        self.ss.h
    }

    /// Transport keys after the handshake: (send, receive) for this side.
    pub fn split(&self) -> (CipherState, CipherState) {
        let (c1, c2) = self.ss.split();
        if self.initiator {
            (c1, c2)
        } else {
            (c2, c1)
        }
    }
}

pub fn public_key(s: &StaticSecret) -> [u8; 32] {
    *PublicKey::from(s).as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::{hex, unhex};

    fn sk(h: &str) -> StaticSecret {
        StaticSecret::from(<[u8; 32]>::try_from(unhex(h)).unwrap())
    }

    /// Every Noise_XX_25519_ChaChaPoly_SHA256 vector in docs/noise-vectors.json (official
    /// cacophony / noise-c / snow vectors), both roles, handshake and transport messages.
    #[test]
    fn official_vectors() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/noise-vectors.json");
        let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut n = 0;
        for v in doc["vectors"].as_array().unwrap() {
            assert_eq!(v["protocol_name"], "Noise_XX_25519_ChaChaPoly_SHA256");
            let g = |k: &str| v[k].as_str().unwrap().to_string();
            let mut ini = HandshakeXX::new(true, sk(&g("init_static")), &unhex(&g("init_prologue")), Some(sk(&g("init_ephemeral"))));
            let mut res = HandshakeXX::new(false, sk(&g("resp_static")), &unhex(&g("resp_prologue")), Some(sk(&g("resp_ephemeral"))));
            let mut tx_i = None;
            let mut tx_r = None;
            for (i, m) in v["messages"].as_array().unwrap().iter().enumerate() {
                let pt = unhex(m["payload"].as_str().unwrap());
                let ct = unhex(m["ciphertext"].as_str().unwrap());
                let init_sends = i % 2 == 0;
                if i < 3 {
                    let (a, b) = if init_sends { (&mut ini, &mut res) } else { (&mut res, &mut ini) };
                    let out = a.write_message(&pt).unwrap();
                    assert_eq!(hex(&out), hex(&ct), "{}: handshake message {i}", v["source"]);
                    assert_eq!(b.read_message(&out).unwrap(), pt);
                    if i == 2 {
                        assert!(ini.is_finished() && res.is_finished());
                        assert_eq!(ini.handshake_hash(), res.handshake_hash());
                        if let Some(h) = v["handshake_hash"].as_str() {
                            assert_eq!(hex(&ini.handshake_hash()), h);
                        }
                        assert_eq!(ini.remote_static(), Some(public_key(&sk(&g("resp_static")))));
                        assert_eq!(res.remote_static(), Some(public_key(&sk(&g("init_static")))));
                        tx_i = Some(ini.split());
                        tx_r = Some(res.split());
                    }
                } else {
                    let (si, ri) = tx_i.as_mut().unwrap();
                    let (sr, rr) = tx_r.as_mut().unwrap();
                    let (tx, rx) = if init_sends { (si, rr) } else { (sr, ri) };
                    let out = tx.encrypt_with_ad(&[], &pt);
                    assert_eq!(hex(&out), hex(&ct), "{}: transport message {i}", v["source"]);
                    assert_eq!(rx.decrypt_with_ad(&[], &out).unwrap(), pt);
                }
            }
            n += 1;
        }
        assert!(n >= 3, "expected the cacophony, noise-c and snow vectors");
    }

    #[test]
    fn tampering_and_order_are_rejected() {
        let mut ini = HandshakeXX::new(true, StaticSecret::random_from_rng(&mut os_rng()), b"p", None);
        let mut res = HandshakeXX::new(false, StaticSecret::random_from_rng(&mut os_rng()), b"p", None);
        assert_eq!(ini.read_message(&[0; 64]), Err(NoiseError::State));
        let m1 = ini.write_message(&[]).unwrap();
        res.read_message(&m1).unwrap();
        let mut m2 = res.write_message(b"hi").unwrap();
        m2[40] ^= 1; // inside the encrypted static key
        assert_eq!(ini.read_message(&m2), Err(NoiseError::Decrypt));
        // A different prologue breaks message 2 authentication.
        let mut ini = HandshakeXX::new(true, StaticSecret::random_from_rng(&mut os_rng()), b"p1", None);
        let mut res = HandshakeXX::new(false, StaticSecret::random_from_rng(&mut os_rng()), b"p2", None);
        res.read_message(&ini.write_message(&[]).unwrap()).unwrap();
        assert_eq!(ini.read_message(&res.write_message(&[]).unwrap()), Err(NoiseError::Decrypt));
        // Low-order ephemeral (all zeros) is rejected.
        let mut res = HandshakeXX::new(false, StaticSecret::random_from_rng(&mut os_rng()), b"", None);
        res.read_message(&[0u8; 32]).unwrap();
        assert_eq!(res.write_message(&[]).err(), Some(NoiseError::BadKey));
    }

    /// Primitive known-answer tests, independent of the Glide transcripts: they pin the crypto
    /// crates' behavior (RFC 7748 X25519, SHA-256, RFC 5869 HKDF-SHA256 as Noise uses it, and the
    /// Noise ChaChaPoly CipherState with the 4-zero-bytes || u64 LE nonce) so a dependency bump
    /// that silently changed any of them fails here. Expected values come from Python
    /// `cryptography` (OpenSSL) and RFC 7748 section 6.1.
    #[test]
    fn primitive_known_answers() {
        // RFC 7748 section 6.1 (Alice/Bob).
        let a = sk("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        let b = sk("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
        assert_eq!(hex(&public_key(&a)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
        assert_eq!(hex(&public_key(&b)), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
        let k = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
        assert_eq!(hex(&dh(&a, &public_key(&b)).unwrap()), k);
        assert_eq!(hex(&dh(&b, &public_key(&a)).unwrap()), k);
        // Low-order point (all zeros) is still rejected.
        assert_eq!(dh(&a, &[0u8; 32]).err(), Some(NoiseError::BadKey));

        // SHA-256("abc"), FIPS 180-2.
        assert_eq!(hex(&Sha256::digest(b"abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

        // Noise HKDF (two outputs, salt = chaining key, empty info).
        let ck: [u8; 32] = std::array::from_fn(|i| 100 + i as u8);
        let ikm: [u8; 32] = std::array::from_fn(|i| i as u8);
        let (o1, o2) = hkdf2(&ck, &ikm);
        assert_eq!(hex(&o1), "ebd88cc897feccb318891f3706718c7e605ff89cb10bda74651309473bc5e99e");
        assert_eq!(hex(&o2), "d7b7c00c25348f173026e96791bb73b42823b1a76f143d2feb80f1f04cd79b53");

        // CipherState: ChaCha20-Poly1305, nonce = 4 zero bytes || u64 LE counter, with AD.
        let key: [u8; 32] = std::array::from_fn(|i| i as u8);
        let pt = b"Glide dependency bump known-answer test";
        let mut enc = CipherState { k: Some(key), n: 5 };
        let ct = enc.encrypt_with_ad(b"hdr", pt);
        assert_eq!(
            hex(&ct),
            "6464ff6e2005235bfbcf572c40db53dabe5cf62884786a661b42c99c759a0abd6007768e1e0446799d5a0884cc0a4e8df74e8436434793"
        );
        assert_eq!(enc.n, 6);
        let mut dec = CipherState { k: Some(key), n: 5 };
        assert_eq!(dec.decrypt_with_ad(b"hdr", &ct).unwrap(), pt);
        let mut wrong_ad = CipherState { k: Some(key), n: 5 };
        assert_eq!(wrong_ad.decrypt_with_ad(b"hdR", &ct).err(), Some(NoiseError::Decrypt));
    }
}
