//! Record layer (docs/PROTOCOL.md §2): `u32 length || ChaCha20-Poly1305(ciphertext+tag)`, keyed
//! with the Noise transport keys from the v2 handshake (`handshake`, `noise`). The nonce layout
//! (4 zero bytes || u64 LE counter) and empty AAD are exactly Noise's transport CipherState.
//! Platform independent; verified against docs/test-vectors*.json.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use std::fmt;
use std::io::Read;

/// The OS CSPRNG as a rand_core 0.10 `CryptoRng` (what x25519-dalek 3 wants). Like rand_core 0.6's `OsRng`,
/// it panics if the OS cannot supply entropy rather than returning weak randomness.
pub fn os_rng() -> getrandom::rand_core::UnwrapErr<getrandom::SysRng> {
    getrandom::rand_core::UnwrapErr(getrandom::SysRng)
}

pub const TAG_LEN: usize = 16;
pub const MIN_RECORD: usize = 17;
pub const MAX_RECORD: usize = 32 * 1024 * 1024;

#[derive(Debug)]
pub enum CryptoError {
    BadRecordLength(usize),
    DecryptFailed,
    Io(std::io::Error),
}

impl fmt::Display for CryptoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CryptoError::BadRecordLength(n) => write!(f, "bad record length {n}"),
            CryptoError::DecryptFailed => write!(f, "record decryption failed"),
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
        Sealer { cipher: ChaCha20Poly1305::new(&Key::from(*key)), counter: 0 }
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
            .encrypt(&Nonce::from(nonce), Payload { msg: plaintext, aad: b"" })
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
        Opener { cipher: ChaCha20Poly1305::new(&Key::from(*key)), counter: 0 }
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
            .decrypt(&Nonce::from(nonce), Payload { msg: ciphertext, aad: b"" })
            .map_err(|_| CryptoError::DecryptFailed)?;
        self.counter += 1;
        Ok(pt)
    }

    /// Read one length-prefixed record from `r` and decrypt it.
    pub fn read_record<R: Read>(&mut self, r: &mut R, buf: &mut Vec<u8>) -> Result<Vec<u8>, CryptoError> {
        self.read_record_max(r, buf, MAX_RECORD)
    }

    /// Like `read_record`, rejecting a record body (ciphertext + tag) longer than `max` before
    /// reading it (pre-auth phases only expect small records).
    pub fn read_record_max<R: Read>(&mut self, r: &mut R, buf: &mut Vec<u8>, max: usize) -> Result<Vec<u8>, CryptoError> {
        let mut len = [0u8; 4];
        r.read_exact(&mut len)?;
        let n = u32::from_le_bytes(len) as usize;
        if !(MIN_RECORD..=max.min(MAX_RECORD)).contains(&n) {
            return Err(CryptoError::BadRecordLength(n));
        }
        buf.resize(n, 0);
        r.read_exact(buf)?;
        self.open(buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::unhex;
    use std::io::Cursor;

    fn session(doc: &serde_json::Value, i: usize) -> &serde_json::Value {
        &doc["sessions"][i]
    }

    /// Records of the Python reference transcript: seal reproduces the bytes, open inverts them,
    /// tampering and replay fail, the counter only advances on success.
    #[test]
    fn records_match_reference_and_detect_tampering() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../docs/test-vectors.json");
        let doc: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        for i in 0..2 {
            let s = session(&doc, i);
            let c2s: [u8; 32] = unhex(s["c2s_key"].as_str().unwrap()).try_into().unwrap();
            let s2c: [u8; 32] = unhex(s["s2c_key"].as_str().unwrap()).try_into().unwrap();
            let (mut sc, mut ss) = (Sealer::new(&c2s), Sealer::new(&s2c));
            let (mut oc, mut os) = (Opener::new(&c2s), Opener::new(&s2c));
            for r in s["records"].as_array().unwrap() {
                let pt = unhex(r["plaintext"].as_str().unwrap());
                let rec = unhex(r["record"].as_str().unwrap());
                let c2s_dir = r["dir"] == "c2s";
                let sealed = if c2s_dir { sc.seal(&pt) } else { ss.seal(&pt) };
                assert_eq!(sealed, rec);
                let o = if c2s_dir { &mut oc } else { &mut os };
                let mut bad = rec[4..].to_vec();
                bad[0] ^= 1;
                let before = o.counter();
                assert!(matches!(o.open(&bad), Err(CryptoError::DecryptFailed)));
                assert_eq!(o.counter(), before, "counter must not advance on failure");
                let mut cur = Cursor::new(rec.clone());
                assert_eq!(o.read_record(&mut cur, &mut Vec::new()).unwrap(), pt);
                assert!(o.open(&rec[4..]).is_err(), "replay at the next counter must fail");
                // undo the failed replay's (non-)effect: counters stay in step with the sealer
                assert_eq!(o.counter(), before + 1);
            }
        }
    }

    #[test]
    fn record_length_bounds() {
        let mut o = Opener::new(&[0u8; 32]);
        let mut cur = Cursor::new(16u32.to_le_bytes().to_vec());
        assert!(matches!(o.read_record(&mut cur, &mut vec![]), Err(CryptoError::BadRecordLength(16))));
        let mut cur = Cursor::new(((32u32 << 20) + 1).to_le_bytes().to_vec());
        assert!(matches!(o.read_record(&mut cur, &mut vec![]), Err(CryptoError::BadRecordLength(_))));
    }

    /// Record layer known answers from an independent implementation (Python `cryptography`):
    /// key 00..1f, empty AAD, nonce = 4 zero bytes || u64 LE counter.
    #[test]
    fn record_layer_known_answers() {
        let key: [u8; 32] = std::array::from_fn(|i| i as u8);
        let pt = b"Glide dependency bump known-answer test";
        let cases: [(u64, &str); 3] = [
            (0, "5fd42b55c8c6c2b463043205ca2d2d5ed8d38698918d3032838f923f4b5b062b177a2819b49d4899edf4d0118d3892cb9c928a007597a6"),
            (1, "d83b9a3bd00acb7d59d3c03837fbfafee51f9e63374b0bc3ac13db76ec86aed3bd38f6d881bbab9e1aee6eb4e14e203de7634872bf5c7e"),
            (0x0102030405060708, "b725c480ce198e7d14ce44a8161602c1c06487a9f8642ef03842c970886cd4aa3c0e20c9b7417dabf0701390107e8d74d27934d4cb1f3d"),
        ];
        for (counter, want) in cases {
            let mut s = Sealer::new(&key);
            s.counter = counter;
            let rec = s.seal(pt);
            assert_eq!(rec[..4], (rec.len() as u32 - 4).to_le_bytes());
            assert_eq!(crate::util::hex(&rec[4..]), want, "counter {counter}");
            let mut o = Opener::new(&key);
            o.counter = counter;
            assert_eq!(o.open(&rec[4..]).unwrap(), pt);
        }
    }
}
