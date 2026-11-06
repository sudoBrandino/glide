#!/usr/bin/env python3
"""Reference implementation of the Glide v1 handshake + record layer.
Generates docs/test-vectors.json. Independent of the Swift and Rust code."""
import hashlib, json, struct, sys
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization

raw = lambda k: k.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
client_priv_b = bytes(range(1, 33))
host_priv_b = bytes(range(101, 133))
client_nonce = bytes([0xA0 + i for i in range(16)])
host_nonce = bytes([0xC0 + i for i in range(16)])
salt = bytes([0x50 + i for i in range(16)])
password = "correct horse battery staple"

cpriv = X25519PrivateKey.from_private_bytes(client_priv_b)
hpriv = X25519PrivateKey.from_private_bytes(host_priv_b)
client_hs = b"GLD1" + struct.pack("<H", 1) + raw(cpriv) + client_nonce
host_hs = b"GLD1" + struct.pack("<H", 1) + raw(hpriv) + host_nonce + salt
assert len(client_hs) == 54 and len(host_hs) == 70

pw_key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 100000, 32)
shared = cpriv.exchange(hpriv.public_key())
assert shared == hpriv.exchange(cpriv.public_key())
okm = HKDF(algorithm=hashes.SHA256(), length=64, salt=hashlib.sha256(client_hs + host_hs).digest(),
           info=b"glide v1 session keys").derive(shared + pw_key)
c2s, s2c = okm[:32], okm[32:]

def record(key, counter, plaintext):
    nonce = b"\0\0\0\0" + struct.pack("<Q", counter)
    ct = ChaCha20Poly1305(key).encrypt(nonce, plaintext, b"")
    return struct.pack("<I", len(ct)) + ct

def s(b): return struct.pack("<H", len(b.encode())) + b.encode()
client_hello = bytes([0x01]) + struct.pack("<HIHHBB", 1, 0b111, 3840, 2160, 0, 60) + s("test-client")
server_hello = bytes([0x02]) + struct.pack("<H", 1) + s("test-host") + struct.pack("<HHBBBf", 2560, 1440, 1, 0, 0, 2.0)
mouse = bytes([0x10]) + struct.pack("<ff", 0.25, 0.75)

out = {
  "password": password,
  "client_private": client_priv_b.hex(), "host_private": host_priv_b.hex(),
  "client_handshake": client_hs.hex(), "host_handshake": host_hs.hex(),
  "pw_key": pw_key.hex(), "shared": shared.hex(), "c2s_key": c2s.hex(), "s2c_key": s2c.hex(),
  "records": [
    {"dir": "c2s", "counter": 0, "plaintext": client_hello.hex(), "record": record(c2s, 0, client_hello).hex()},
    {"dir": "c2s", "counter": 1, "plaintext": mouse.hex(), "record": record(c2s, 1, mouse).hex()},
    {"dir": "s2c", "counter": 0, "plaintext": server_hello.hex(), "record": record(s2c, 0, server_hello).hex()},
  ],
}
json.dump(out, open(sys.argv[1] if len(sys.argv) > 1 else "docs/test-vectors.json", "w"), indent=2)
print("ok")
