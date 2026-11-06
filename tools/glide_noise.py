"""Reference implementation of the Glide v2 handshake (docs/PROTOCOL.md §1–2):
Noise_XX_25519_ChaChaPoly_SHA256 (Noise spec rev 34) plus Glide's preambles, payloads, pairing
commitment and Short Authentication String.

Used by tools/gen_vectors.py (test vectors) and tools/mock_host.py (mock host). Written from the
Noise spec, independent of the Swift and Rust code; checked against the official vectors in
docs/noise-vectors.json (`python3 tools/glide_noise.py` runs that check).
"""
import hashlib, hmac, json, os, struct
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives import serialization

PROTOCOL_NAME = b"Noise_XX_25519_ChaChaPoly_SHA256"
DHLEN, HASHLEN = 32, 32

MAGIC_V2 = b"GLD2"
MAGIC_V1 = b"GLD1"
VERSION = 2
CLIENT_PREAMBLE_LEN = 24
HOST_PREAMBLE_LEN = 8
MAX_HANDSHAKE_MSG = 1024
# HostPreamble status
ST_OK, ST_UNSUPPORTED_VERSION, ST_PAUSED, ST_RATE_LIMITED = 0, 1, 2, 3
# msg2 / msg3 flags
HOST_FLAG_PAIRING_OPEN = 1
VIEWER_FLAG_PAIR_REQUEST = 1
# AuthResult codes
AUTH_OK, AUTH_UNKNOWN_VIEWER, AUTH_PAIRING_CLOSED, AUTH_DECLINED, AUTH_TIMEOUT, AUTH_BUSY = 0, 1, 2, 3, 4, 5
# Record message types used by the auth phase
MSG_AUTH_RESULT, MSG_PAIR_REVEAL, MSG_PAIR_CONFIRM = 0x05, 0x06, 0x07

COMMIT_LABEL = b"glide-v2 pair commit"
SAS_LABEL = b"glide-v2 sas"


def raw_pub(priv):
    return priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def priv_from(b):
    return X25519PrivateKey.from_private_bytes(bytes(b))


def dh(priv, pub_bytes):
    return priv.exchange(X25519PublicKey.from_public_bytes(pub_bytes))


def hkdf2(ck, ikm):
    """Noise HKDF with two outputs (== RFC 5869 HKDF-SHA256, salt=ck, info=empty, L=64)."""
    tmp = hmac.new(ck, ikm, hashlib.sha256).digest()
    o1 = hmac.new(tmp, b"\x01", hashlib.sha256).digest()
    o2 = hmac.new(tmp, o1 + b"\x02", hashlib.sha256).digest()
    return o1, o2


def nonce_bytes(n):
    return b"\0\0\0\0" + struct.pack("<Q", n)


class CipherState:
    def __init__(self, k=None):
        self.k, self.n = k, 0

    def has_key(self):
        return self.k is not None

    def encrypt_with_ad(self, ad, pt):
        if self.k is None:
            return pt
        ct = ChaCha20Poly1305(self.k).encrypt(nonce_bytes(self.n), pt, ad)
        self.n += 1
        return ct

    def decrypt_with_ad(self, ad, ct):
        if self.k is None:
            return ct
        pt = ChaCha20Poly1305(self.k).decrypt(nonce_bytes(self.n), ct, ad)  # raises InvalidTag
        self.n += 1
        return pt


class SymmetricState:
    def __init__(self, name):
        self.h = name.ljust(HASHLEN, b"\0") if len(name) <= HASHLEN else hashlib.sha256(name).digest()
        self.ck = self.h
        self.cs = CipherState()

    def mix_key(self, ikm):
        self.ck, k = hkdf2(self.ck, ikm)
        self.cs = CipherState(k)

    def mix_hash(self, data):
        self.h = hashlib.sha256(self.h + data).digest()

    def encrypt_and_hash(self, pt):
        ct = self.cs.encrypt_with_ad(self.h, pt)
        self.mix_hash(ct)
        return ct

    def decrypt_and_hash(self, ct):
        pt = self.cs.decrypt_with_ad(self.h, ct)
        self.mix_hash(ct)
        return pt

    def split(self):
        k1, k2 = hkdf2(self.ck, b"")
        return CipherState(k1), CipherState(k2)


class HandshakeXX:
    """Noise XX: -> e ; <- e, ee, s, es ; -> s, se. Only what Glide needs, both roles."""

    def __init__(self, initiator, s, prologue=b"", e=None):
        self.initiator = initiator
        self.s = s                      # X25519PrivateKey (static)
        self.e = e                      # optional fixed ephemeral (tests/vectors)
        self.rs = self.re = None
        self.ss = SymmetricState(PROTOCOL_NAME)
        self.ss.mix_hash(prologue)
        self.step = 0

    def _eph(self):
        if self.e is None:
            self.e = X25519PrivateKey.generate()
        return self.e

    def write_message(self, payload=b""):
        st = self.ss
        if self.initiator and self.step == 0:      # -> e
            e = self._eph(); out = raw_pub(e); st.mix_hash(out)
        elif not self.initiator and self.step == 1:  # <- e, ee, s, es
            e = self._eph(); out = raw_pub(e); st.mix_hash(out)
            st.mix_key(dh(e, self.re))
            out += st.encrypt_and_hash(raw_pub(self.s))
            st.mix_key(dh(self.s, self.re))
        elif self.initiator and self.step == 2:    # -> s, se
            out = st.encrypt_and_hash(raw_pub(self.s))
            st.mix_key(dh(self.s, self.re))
        else:
            raise ValueError("write_message out of turn")
        out += st.encrypt_and_hash(payload)
        self.step += 1
        return out

    def read_message(self, msg):
        st = self.ss
        if not self.initiator and self.step == 0:  # -> e
            if len(msg) < DHLEN:
                raise ValueError("short message")
            self.re = msg[:DHLEN]; st.mix_hash(self.re); rest = msg[DHLEN:]
        elif self.initiator and self.step == 1:    # <- e, ee, s, es
            if len(msg) < DHLEN + DHLEN + 16 + 16:
                raise ValueError("short message")
            self.re = msg[:DHLEN]; st.mix_hash(self.re)
            st.mix_key(dh(self.e, self.re))
            self.rs = st.decrypt_and_hash(msg[DHLEN:DHLEN + 48])
            st.mix_key(dh(self.e, self.rs))
            rest = msg[DHLEN + 48:]
        elif not self.initiator and self.step == 2:  # -> s, se
            if len(msg) < 48 + 16:
                raise ValueError("short message")
            self.rs = st.decrypt_and_hash(msg[:48])
            st.mix_key(dh(self.e, self.rs))
            rest = msg[48:]
        else:
            raise ValueError("read_message out of turn")
        payload = st.decrypt_and_hash(rest)
        self.step += 1
        return payload

    def finished(self):
        return self.step == 3

    def handshake_hash(self):
        return self.ss.h

    def split(self):
        """Returns (send, recv) CipherStates for this side."""
        c1, c2 = self.ss.split()
        return (c1, c2) if self.initiator else (c2, c1)


# ---------------------------------------------------------------- Glide v2 framing + payloads

def client_preamble(max_version=VERSION, min_version=VERSION):
    return MAGIC_V2 + struct.pack("<HH", max_version, min_version) + bytes(16)


def host_preamble(version=VERSION, status=ST_OK):
    return MAGIC_V2 + struct.pack("<HH", version, status)


def frame(msg):
    assert len(msg) <= MAX_HANDSHAKE_MSG
    return struct.pack("<H", len(msg)) + msg


def commitment(n_h):
    return hashlib.sha256(COMMIT_LABEL + n_h).digest()


def msg2_payload(flags, n_h, version=VERSION):
    return struct.pack("<HB", version, flags) + commitment(n_h)


def parse_msg2_payload(p):
    if len(p) < 35:
        raise ValueError("short msg2 payload")
    version, flags = struct.unpack("<HB", p[:3])
    return version, flags, p[3:35]


def pstr(s):
    b = s.encode()[:255]
    return struct.pack("<H", len(b)) + b


def msg3_payload(flags, n_v, name):
    return bytes([flags]) + n_v + pstr(name)


def parse_msg3_payload(p):
    if len(p) < 35:
        raise ValueError("short msg3 payload")
    flags, n_v = p[0], p[1:33]
    (ln,) = struct.unpack("<H", p[33:35])
    if len(p) < 35 + ln:
        raise ValueError("truncated viewer name")
    return flags, n_v, p[35:35 + ln].decode("utf-8", "replace")


def sas_code(h, n_v, n_h):
    """6-digit Short Authentication String, as an int (display: '%03d %03d')."""
    d = hashlib.sha256(SAS_LABEL + h + n_v + n_h).digest()
    return int.from_bytes(d[:4], "big") % 1_000_000


def sas_text(code):
    return f"{code // 1000:03d} {code % 1000:03d}"


def fingerprint(pub):
    d = hashlib.sha256(pub).hexdigest()[:16]
    return " ".join(d[i:i + 4] for i in range(0, 16, 4))


def record(cs, pt):
    """Seal one record with a transport CipherState: u32 length || ciphertext+tag (AAD empty)."""
    ct = cs.encrypt_with_ad(b"", pt)
    return struct.pack("<I", len(ct)) + ct


# ---------------------------------------------------------------- official vectors

def check_noise_vectors(path):
    """Run every Noise_XX_25519_ChaChaPoly_SHA256 vector in `path`; returns the count checked."""
    vs = json.load(open(path))["vectors"]
    n = 0
    for v in vs:
        if v.get("protocol_name", v.get("name")) != PROTOCOL_NAME.decode():
            continue
        ini = HandshakeXX(True, priv_from(bytes.fromhex(v["init_static"])), bytes.fromhex(v["init_prologue"]),
                          priv_from(bytes.fromhex(v["init_ephemeral"])))
        res = HandshakeXX(False, priv_from(bytes.fromhex(v["resp_static"])), bytes.fromhex(v["resp_prologue"]),
                          priv_from(bytes.fromhex(v["resp_ephemeral"])))
        send_i = recv_i = send_r = recv_r = None
        for i, m in enumerate(v["messages"]):
            pt, ct = bytes.fromhex(m["payload"]), bytes.fromhex(m["ciphertext"])
            init_sends = i % 2 == 0
            if i < 3:
                a, b = (ini, res) if init_sends else (res, ini)
                out = a.write_message(pt)
                assert out == ct, f"{v.get('source', '?')}: handshake message {i} mismatch"
                assert b.read_message(out) == pt
                if i == 2:
                    assert ini.handshake_hash() == res.handshake_hash()
                    if "handshake_hash" in v:
                        assert ini.handshake_hash().hex() == v["handshake_hash"], "handshake hash mismatch"
                    send_i, recv_i = ini.split()
                    send_r, recv_r = res.split()
            else:
                tx, rx = (send_i, recv_r) if init_sends else (send_r, recv_i)
                out = tx.encrypt_with_ad(b"", pt)
                assert out == ct, f"transport message {i} mismatch"
                assert rx.decrypt_with_ad(b"", out) == pt
        n += 1
    return n


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    n = check_noise_vectors(os.path.join(here, "..", "docs", "noise-vectors.json"))
    print(f"ok: {n} Noise_XX_25519_ChaChaPoly_SHA256 vectors")
