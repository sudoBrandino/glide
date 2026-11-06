//! Glide v1 handshake, key derivation and record layer (docs/PROTOCOL.md §1–2).
//! Platform independent; verified against docs/test-vectors.json.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::{Read, Write};
use x25519_dalek::{PublicKey, StaticSecret};

pub const MAGIC: &[u8; 4] = b"GLD1";
pub const CLIENT_HS_LEN: usize = 54;
pub const HOST_HS_LEN: usize = 70;
pub const PBKDF2_ITERATIONS: u32 = 100_000;
pub const HKDF_INFO: &[u8] = b"glide v1 session keys";
pub const TAG_LEN: usize = 16;
pub const MIN_RECORD: usize = 17;
pub const MAX_RECORD: usize = 32 * 1024 * 1024;

#[derive(Debug)]
pub enum CryptoError {
    BadMagic,
    BadVersion(u16),
    BadRecordLength(usize),
    DecryptFailed,
    Io(std::io::Error),
}

impl fmt::Display for CryptoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CryptoError::BadMagic => write!(f, "bad handshake magic"),
            CryptoError::BadVersion(v) => write!(f, "unsupported protocol version {v}"),
            CryptoError::BadRecordLength(n) => write!(f, "bad record length {n}"),
            CryptoError::DecryptFailed => write!(f, "record decryption failed (wrong password?)"),
            CryptoError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for CryptoError {}

impl From<std::io::Error> for CryptoError {
    fn from(e: std::io::Error) -> Self {
        CryptoError::Io(e)
    }
}

/// Session keys for both directions.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SessionKeys {
    pub c2s: [u8; 32],
    pub s2c: [u8; 32],
}

pub fn pw_key(password: &str, salt: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(password.as_bytes(), salt, PBKDF2_ITERATIONS, &mut out);
    out
}

pub fn derive_keys(shared: &[u8; 32], pw_key: &[u8; 32], client_hs: &[u8], host_hs: &[u8]) -> SessionKeys {
    let mut h = Sha256::new();
    h.update(client_hs);
    h.update(host_hs);
    let salt = h.finalize();
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(shared);
    ikm[32..].copy_from_slice(pw_key);
    let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
    let mut okm = [0u8; 64];
    hk.expand(HKDF_INFO, &mut okm).expect("64 bytes is a valid HKDF length");
    let mut c2s = [0u8; 32];
    let mut s2c = [0u8; 32];
    c2s.copy_from_slice(&okm[..32]);
    s2c.copy_from_slice(&okm[32..]);
    SessionKeys { c2s, s2c }
}

pub fn build_client_handshake(public: &PublicKey, nonce: &[u8; 16]) -> [u8; CLIENT_HS_LEN] {
    let mut out = [0u8; CLIENT_HS_LEN];
    out[0..4].copy_from_slice(MAGIC);
    out[4..6].copy_from_slice(&1u16.to_le_bytes());
    out[6..38].copy_from_slice(public.as_bytes());
    out[38..54].copy_from_slice(nonce);
    out
}

pub struct ParsedHostHandshake {
    pub public: [u8; 32],
    pub nonce: [u8; 16],
    pub salt: [u8; 16],
}

pub fn parse_host_handshake(hs: &[u8; HOST_HS_LEN]) -> Result<ParsedHostHandshake, CryptoError> {
    if &hs[0..4] != MAGIC {
        return Err(CryptoError::BadMagic);
    }
    let v = u16::from_le_bytes([hs[4], hs[5]]);
    if v != crate::protocol::PROTOCOL_VERSION {
        return Err(CryptoError::BadVersion(v));
    }
    Ok(ParsedHostHandshake {
        public: hs[6..38].try_into().unwrap(),
        nonce: hs[38..54].try_into().unwrap(),
        salt: hs[54..70].try_into().unwrap(),
    })
}

fn nonce_for(counter: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&counter.to_le_bytes());
    n
}

/// Encrypts outgoing records. One instance per direction; owns the counter.
pub struct Sealer {
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl Sealer {
    pub fn new(key: &[u8; 32]) -> Self {
        Sealer { cipher: ChaCha20Poly1305::new(Key::from_slice(key)), counter: 0 }
    }
    pub fn counter(&self) -> u64 {
        self.counter
    }
    /// Returns the full record: `u32 len || ciphertext+tag`.
    pub fn seal(&mut self, plaintext: &[u8]) -> Vec<u8> {
        let nonce = nonce_for(self.counter);
        self.counter += 1;
        let ct = self
            .cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: plaintext, aad: b"" })
            .expect("chacha20poly1305 encrypt cannot fail");
        let mut out = Vec::with_capacity(4 + ct.len());
        out.extend_from_slice(&(ct.len() as u32).to_le_bytes());
        out.extend_from_slice(&ct);
        out
    }
}

/// Decrypts incoming records. One instance per direction; owns the counter.
pub struct Opener {
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl Opener {
    pub fn new(key: &[u8; 32]) -> Self {
        Opener { cipher: ChaCha20Poly1305::new(Key::from_slice(key)), counter: 0 }
    }
    pub fn counter(&self) -> u64 {
        self.counter
    }
    /// Decrypt one record body (ciphertext+tag, without the length prefix).
    pub fn open(&mut self, ciphertext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        if ciphertext.len() < MIN_RECORD || ciphertext.len() > MAX_RECORD {
            return Err(CryptoError::BadRecordLength(ciphertext.len()));
        }
        let nonce = nonce_for(self.counter);
        let pt = self
            .cipher
            .decrypt(Nonce::from_slice(&nonce), Payload { msg: ciphertext, aad: b"" })
            .map_err(|_| CryptoError::DecryptFailed)?;
        self.counter += 1;
        Ok(pt)
    }

    /// Read one length-prefixed record from `r` and decrypt it.
    pub fn read_record<R: Read>(&mut self, r: &mut R, buf: &mut Vec<u8>) -> Result<Vec<u8>, CryptoError> {
        let mut len = [0u8; 4];
        r.read_exact(&mut len)?;
        let n = u32::from_le_bytes(len) as usize;
        if !(MIN_RECORD..=MAX_RECORD).contains(&n) {
            return Err(CryptoError::BadRecordLength(n));
        }
        buf.resize(n, 0);
        r.read_exact(buf)?;
        self.open(buf)
    }
}

/// Result of a completed client-side handshake.
pub struct ClientSession {
    pub sealer: Sealer,
    pub opener: Opener,
    pub keys: SessionKeys,
}

/// Perform the client side of the handshake given explicit key material
/// (deterministic; used by tests). `stream` must be connected to the host.
pub fn client_handshake_with<S: Read + Write>(
    stream: &mut S,
    password: &str,
    secret: StaticSecret,
    nonce: [u8; 16],
) -> Result<ClientSession, CryptoError> {
    let public = PublicKey::from(&secret);
    let chs = build_client_handshake(&public, &nonce);
    stream.write_all(&chs)?;
    stream.flush()?;
    let mut hhs = [0u8; HOST_HS_LEN];
    stream.read_exact(&mut hhs)?;
    let parsed = parse_host_handshake(&hhs)?;
    let shared = secret.diffie_hellman(&PublicKey::from(parsed.public));
    let pwk = pw_key(password, &parsed.salt);
    let keys = derive_keys(shared.as_bytes(), &pwk, &chs, &hhs);
    Ok(ClientSession { sealer: Sealer::new(&keys.c2s), opener: Opener::new(&keys.s2c), keys })
}

/// Perform the client side of the handshake with fresh random key material.
pub fn client_handshake<S: Read + Write>(stream: &mut S, password: &str) -> Result<ClientSession, CryptoError> {
    let secret = StaticSecret::random_from_rng(OsRng);
    let mut nonce = [0u8; 16];
    OsRng.fill_bytes(&mut nonce);
    client_handshake_with(stream, password, secret, nonce)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::{hex, unhex};
    use std::io::Cursor;

    /// Minimal flat-JSON reader for docs/test-vectors.json (avoids a serde dependency).
    struct Vectors(String);
    impl Vectors {
        fn load() -> Vectors {
            let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/test-vectors.json");
            Vectors(std::fs::read_to_string(path).expect("read docs/test-vectors.json"))
        }
        /// Value of the n-th occurrence of `"key": "value"`.
        fn get_nth(&self, key: &str, n: usize) -> String {
            let pat = format!("\"{key}\":");
            let mut from = 0;
            let mut idx = 0;
            loop {
                let at = self.0[from..].find(&pat).unwrap_or_else(|| panic!("key {key}#{n} not found")) + from;
                let rest = self.0[at + pat.len()..].trim_start();
                if idx == n {
                    if let Some(s) = rest.strip_prefix('"') {
                        return s[..s.find('"').unwrap()].to_string();
                    }
                    let end = rest.find(|c: char| c == ',' || c == '\n' || c == '}').unwrap();
                    return rest[..end].trim().to_string();
                }
                idx += 1;
                from = at + pat.len();
            }
        }
        fn get(&self, key: &str) -> String {
            self.get_nth(key, 0)
        }
        fn bytes32(&self, key: &str) -> [u8; 32] {
            unhex(&self.get(key)).try_into().unwrap()
        }
    }

    /// Fake host: replays the vector host handshake and records what the client writes.
    struct FakeHost {
        reply: Cursor<Vec<u8>>,
        written: Vec<u8>,
    }
    impl Read for FakeHost {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            self.reply.read(buf)
        }
    }
    impl Write for FakeHost {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.written.extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn pbkdf2_matches_vector() {
        let v = Vectors::load();
        let hhs = unhex(&v.get("host_handshake"));
        assert_eq!(hex(&pw_key(&v.get("password"), &hhs[54..70])), v.get("pw_key"));
    }

    #[test]
    fn x25519_and_hkdf_match_vector() {
        let v = Vectors::load();
        let cpriv = StaticSecret::from(v.bytes32("client_private"));
        let hpriv = StaticSecret::from(v.bytes32("host_private"));
        let shared = cpriv.diffie_hellman(&PublicKey::from(&hpriv));
        assert_eq!(hex(shared.as_bytes()), v.get("shared"));
        let chs = unhex(&v.get("client_handshake"));
        let hhs = unhex(&v.get("host_handshake"));
        let keys = derive_keys(shared.as_bytes(), &v.bytes32("pw_key"), &chs, &hhs);
        assert_eq!(hex(&keys.c2s), v.get("c2s_key"));
        assert_eq!(hex(&keys.s2c), v.get("s2c_key"));
    }

    #[test]
    fn full_client_handshake_reproduces_vectors_byte_for_byte() {
        let v = Vectors::load();
        let hhs = unhex(&v.get("host_handshake"));
        let mut host = FakeHost { reply: Cursor::new(hhs), written: vec![] };
        let nonce: [u8; 16] = std::array::from_fn(|i| 0xA0 + i as u8);
        let mut sess =
            client_handshake_with(&mut host, &v.get("password"), StaticSecret::from(v.bytes32("client_private")), nonce).unwrap();
        // Client handshake bytes on the wire
        assert_eq!(hex(&host.written), v.get("client_handshake"));
        assert_eq!(hex(&sess.keys.c2s), v.get("c2s_key"));
        assert_eq!(hex(&sess.keys.s2c), v.get("s2c_key"));

        // records[0] and [1]: c2s counters 0 and 1
        for i in 0..2 {
            assert_eq!(v.get_nth("dir", i), "c2s");
            assert_eq!(v.get_nth("counter", i), i.to_string());
            let pt = unhex(&v.get_nth("plaintext", i));
            let rec = sess.sealer.seal(&pt);
            assert_eq!(hex(&rec), v.get_nth("record", i), "c2s record {i}");
        }
        // records[2]: s2c counter 0 -> decrypt
        assert_eq!(v.get_nth("dir", 2), "s2c");
        let rec = unhex(&v.get_nth("record", 2));
        let mut cur = Cursor::new(rec.clone());
        let mut buf = Vec::new();
        let pt = sess.opener.read_record(&mut cur, &mut buf).unwrap();
        assert_eq!(hex(&pt), v.get_nth("plaintext", 2));

        // A host-side sealer with s2c key reproduces the s2c record too.
        let mut host_sealer = Sealer::new(&sess.keys.s2c);
        assert_eq!(host_sealer.seal(&pt), rec);
    }

    #[test]
    fn wrong_password_fails_decrypt_and_tamper_detected() {
        let v = Vectors::load();
        let hhs = unhex(&v.get("host_handshake"));
        let mut host = FakeHost { reply: Cursor::new(hhs), written: vec![] };
        let mut sess = client_handshake_with(&mut host, "wrong", StaticSecret::from(v.bytes32("client_private")), [0xA0; 16]).unwrap();
        let rec = unhex(&v.get_nth("record", 2));
        assert!(matches!(sess.opener.open(&rec[4..]), Err(CryptoError::DecryptFailed)));

        let mut good = Opener::new(&v.bytes32("s2c_key"));
        let mut bad = rec[4..].to_vec();
        bad[3] ^= 1;
        assert!(good.open(&bad).is_err());
        assert_eq!(good.counter(), 0, "counter must not advance on failure");
        assert!(good.open(&rec[4..]).is_ok());
        assert!(good.open(&rec[4..]).is_err(), "replay at counter 1 must fail");
    }

    #[test]
    fn record_length_bounds() {
        let mut o = Opener::new(&[0u8; 32]);
        let mut cur = Cursor::new(16u32.to_le_bytes().to_vec());
        assert!(matches!(o.read_record(&mut cur, &mut vec![]), Err(CryptoError::BadRecordLength(16))));
        let mut cur = Cursor::new(((32u32 << 20) + 1).to_le_bytes().to_vec());
        assert!(matches!(o.read_record(&mut cur, &mut vec![]), Err(CryptoError::BadRecordLength(_))));
        let mut hs = [0u8; HOST_HS_LEN];
        hs[..4].copy_from_slice(b"XXXX");
        assert!(matches!(parse_host_handshake(&hs), Err(CryptoError::BadMagic)));
        hs[..4].copy_from_slice(MAGIC);
        hs[4] = 2;
        assert!(matches!(parse_host_handshake(&hs), Err(CryptoError::BadVersion(2))));
    }
}
