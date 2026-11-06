#!/usr/bin/env python3
"""Glide v1 mock host (docs/PROTOCOL.md), for testing the Windows client without the Mac host.

- Performs the handshake + ChaCha20-Poly1305 record layer.
- Replies to ClientHello with ServerHello, then streams an Annex-B file (looped)
  as VideoFrame records at --fps (default 60).
- Picks the stream from the client's caps/mode: sharp + HEVC 4:4:4 cap -> 4:4:4 file,
  else HEVC 4:2:0, else H.264. SetMode switches stream (sends VideoConfig + keyframe).
- Answers Ping with Pong, sends a synthetic cursor shape, logs input messages.
- RequestKeyframe restarts the file at its first keyframe.
- Clipboard (PROTOCOL.md §5): if the client sets caps bit 8, sends ClipboardCaps and logs every
  Clipboard it receives (--clip-save DIR keeps received PNGs). --clip-text/--clip-png push a
  clipboard to the client (--clip-every N repeats it); --clip-bounce sends each received
  clipboard straight back once, to check that the viewer does not echo it again (no ping-pong).
- --selftest checks the clipboard codec against the PROTOCOL.md §5 reference bytes and the file-transfer
  codec/name sanitizer against docs/file-transfer-vectors.json (§6), and exits.
- File transfer (§6, client caps bit 11): sends FileCaps, saves files from the viewer into --file-recv
  (SHA-256 verified, never overwriting); --file-send PATH... offers files ~2 s after connect, --file-pull
  PATH... answers FilePull (Ctrl+Alt+Shift+V), --file-evil sends adversarial offers, --file-decline
  declines everything, --log-pings logs Ping queueing (input priority during uploads).
- Hybrid (mode 2, needs HEVC 4:4:4 cap): ServerHello + SharpLayerConfig, base 4:2:0 stream, a
  sharp-layer 4:4:4 IDR (flags bit2) each --hybrid-period frames, and rect-only base frames (bit3).
- Audio (§3.2, client caps bit 9): AudioConfig + a continuous sine (default 440 Hz, -12 dBFS,
  48 kHz stereo) as ≤10 ms AudioFrames. Any glitch (drop, underrun, click) is easy to hear on a
  pure tone. --audio-burst 1024 mimics ScreenCaptureKit's buffer size, --audio-drift-ppm a host
  clock running fast/slow, --audio-jitter-ms random send delay, --audio-pattern 2000:1000 sends
  nothing for 1 s out of every 3 (like the Mac while silent). AudioEnable(0/1) stops/resumes.

Usage:
  GLIDE_PASSWORD=... python3 tools/mock_host.py [--port 7421 | --connect HOST:PORT [--once]] [--fps 60]
      [--hevc streams/hevc420_1440p.h265] [--hevc444 streams/hevc444_1440p.h265]
      [--h264 streams/h264_1440p.h264] [--switch-every SECONDS] [--quiet-input]
      [--clip-text TEXT | --clip-png FILE] [--clip-every SECONDS] [--clip-bounce] [--clip-save DIR]
      [--no-audio] [--audio-freq HZ] [--audio-right-freq HZ] [--audio-db DBFS] [--audio-burst FRAMES]
      [--audio-drift-ppm PPM] [--audio-jitter-ms MS] [--audio-pattern ON_MS:OFF_MS]
  python3 tools/mock_host.py --selftest
Generate streams first with tools/make_streams.sh.
"""
import argparse, array, hashlib, math, os, random, socket, struct, sys, threading, time
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = time.monotonic_ns()


def mono_us():
    return (time.monotonic_ns() - T0) // 1000


def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, flush=True)


# ---------------------------------------------------------------- Annex-B

def split_nals(data):
    out, i, starts = [], 0, []
    n = len(data)
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            sc = i - 1 if i > 0 and data[i - 1] == 0 else i
            starts.append((sc, i + 3))
            i += 3
        else:
            i += 1
    for k, (_, p) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else n
        nal = data[p:end].rstrip(b"\0")
        if nal:
            out.append(nal)
    return out


def split_aus(data, codec):
    """codec 1 = HEVC, 2 = H.264. Returns [(annexb_bytes_4byte_startcodes, keyframe)]."""
    aus, cur, key, seen_vcl = [], [], False, False
    for nal in split_nals(data):
        if codec == 1:
            t = (nal[0] >> 1) & 0x3F
            vcl = t < 32
            starts = t in (32, 33, 34, 35, 39) or 41 <= t <= 44 or 48 <= t <= 55 or (vcl and len(nal) > 2 and nal[2] & 0x80)
            is_key = 16 <= t <= 23
        else:
            t = nal[0] & 0x1F
            vcl = 1 <= t <= 5
            starts = t in (6, 7, 8, 9) or 14 <= t <= 18 or (t in (1, 5) and len(nal) > 1 and nal[1] & 0x80)
            is_key = t == 5
        if seen_vcl and starts:
            aus.append((b"".join(cur), key))
            cur, key, seen_vcl = [], False, False
        seen_vcl |= vcl
        key |= is_key
        cur.append(b"\0\0\0\1" + nal)
    if cur:
        aus.append((b"".join(cur), key))
    return aus


def hevc_dims(aus):
    """Width/height via ffprobe-free heuristic: parse from SPS (minimal parser)."""
    for au, _ in aus:
        for nal in split_nals(au):
            if ((nal[0] >> 1) & 0x3F) == 33:
                return parse_hevc_sps(nal)
    return None


class Bits:
    def __init__(self, d):
        out, z = bytearray(), 0
        for b in d:
            if z >= 2 and b == 3:
                z = 0
                continue
            z = z + 1 if b == 0 else 0
            out.append(b)
        self.d, self.p = bytes(out), 0

    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.d[self.p // 8] >> (7 - self.p % 8)) & 1)
            self.p += 1
        return v

    def ue(self):
        lz = 0
        while self.u(1) == 0:
            lz += 1
        return (1 << lz) - 1 + self.u(lz)


def parse_hevc_sps(nal):
    b = Bits(nal[2:])
    b.u(4)
    msl = b.u(3)
    b.u(1)
    b.u(96)
    sp, sl = [], []
    for _ in range(msl):
        sp.append(b.u(1)); sl.append(b.u(1))
    if msl > 0:
        for _ in range(msl, 8):
            b.u(2)
    for i in range(msl):
        if sp[i]: b.u(88)
        if sl[i]: b.u(8)
    b.ue()
    chroma = b.ue()
    if chroma == 3:
        b.u(1)
    w, h = b.ue(), b.ue()
    if b.u(1):
        sub_w = 1 if chroma == 3 else 2
        sub_h = 2 if chroma == 1 else 1
        l, r, t, bt = b.ue(), b.ue(), b.ue(), b.ue()
        w -= sub_w * (l + r)
        h -= sub_h * (t + bt)
    return w, h, chroma


class Stream:
    def __init__(self, path, codec, chroma, w=2560, h=1440):
        self.path, self.codec, self.chroma = path, codec, chroma
        data = open(path, "rb").read()
        self.aus = split_aus(data, codec)
        self.w, self.h = w, h
        if codec == 1:
            d = hevc_dims(self.aus)
            if d:
                self.w, self.h, c = d
                self.chroma = 1 if c == 3 else 0
        nkey = sum(1 for _, k in self.aus if k)
        log(f"loaded {os.path.basename(path)}: {len(self.aus)} AUs, {nkey} keyframes, {self.w}x{self.h} "
            f"codec={'HEVC' if codec == 1 else 'H.264'} chroma={'4:4:4' if self.chroma else '4:2:0'} "
            f"avg {len(data) * 8 / max(1, len(self.aus)) / 1000:.0f} kbit/frame")


# ---------------------------------------------------------------- clipboard (§5)

CAP_CLIPBOARD = 1 << 8
CLIP_TEXT, CLIP_PNG = 1, 2
CLIPBOARD_MAX = 16 << 20


def clip_encode(seq, text=None, png=None):
    items = []
    if text is not None:
        items.append((CLIP_TEXT, text.encode()))
    if png is not None:
        items.append((CLIP_PNG, png))
    out = bytes([0x50]) + struct.pack("<IB", seq, len(items))
    for fmt, b in items:
        out += struct.pack("<BI", fmt, len(b)) + b
    return out


def clip_decode(m):
    """Clipboard message (type byte included) -> (seq, text|None, png|None). Raises on truncation."""
    if m[0] != 0x50 or len(m) < 6:
        raise ValueError("not a Clipboard message")
    seq, n = struct.unpack("<IB", m[1:6])
    p, text, png = 6, None, None
    for _ in range(n):
        if p + 5 > len(m):
            raise ValueError("truncated item header")
        fmt, ln = struct.unpack("<BI", m[p:p + 5])
        p += 5
        if p + ln > len(m):
            raise ValueError("truncated item")
        b = m[p:p + ln]
        p += ln
        if fmt == CLIP_TEXT and text is None:
            text = b.decode("utf-8", "replace")
        elif fmt == CLIP_PNG and png is None:
            png = b
    return seq, text, png


def clip_caps(formats=3, max_bytes=CLIPBOARD_MAX):
    return bytes([0x51]) + struct.pack("<II", formats, max_bytes)


def selftest():
    ok = True

    def check(c, what):
        nonlocal ok
        print(("  ok   " if c else "  FAIL ") + what)
        ok &= c

    ref = clip_encode(1, text="hi\n")
    check(ref.hex() == "500100000001010300000068690a", "Clipboard reference bytes")
    check(clip_caps().hex() == "510300000000000001", "ClipboardCaps reference bytes")
    check(clip_decode(ref) == (1, "hi\n", None), "Clipboard decode")
    both = clip_encode(9, text="é\nx", png=b"\x89PNG")
    check(clip_decode(both) == (9, "é\nx", b"\x89PNG"), "text + png roundtrip")
    raw = bytes([0x50, 2, 0, 0, 0, 3]) + bytes([9, 1, 0, 0, 0, 7]) + bytes([1, 2, 0, 0, 0]) + b"ok" + bytes([1, 1, 0, 0, 0]) + b"x"
    check(clip_decode(raw) == (2, "ok", None), "unknown format skipped, duplicate ignored")
    trunc = all(_raises(lambda n=n: clip_decode(both[:n])) for n in range(1, len(both)))
    check(trunc, "truncation rejected")
    file_selftest(check)
    print("ALL TESTS PASSED" if ok else "FAILURES")
    return ok


def _raises(f):
    try:
        f()
    except (ValueError, struct.error):
        return True
    return False


# ---------------------------------------------------------------- file transfer (§6)

CAP_FILES = 1 << 11
FILE_CHUNK_MAX = 256 << 10
FILE_WINDOW = 1 << 20  # protocol maximum
FILE_SEND_WINDOW = 512 << 10  # what Glide senders use
FILE_PATH_MAX = 4096
FILE_MAX_DEPTH = 32
FILE_COMPONENT_MAX = 200
HOST_ID_BIT = 0x80000000
# status / reason codes (FileAnswer, FileCancel, FilePullResult)
ST_OK, ST_DECLINED, ST_TOO_LARGE, ST_BAD_NAME, ST_BUSY, ST_NO_SPACE, ST_IO, ST_CANCELLED, ST_VERIFY, \
    ST_PROTOCOL, ST_SOURCE_CHANGED, ST_NOTHING = range(12)
FORMAT_CHARS = set([0x061C, 0xFEFF] + list(range(0x200B, 0x2010)) + list(range(0x202A, 0x202F)) +
                   list(range(0x2060, 0x2065)) + list(range(0x2066, 0x206A)))
RESERVED = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"} | {f"{p}{d}" for p in ("COM", "LPT")
                                                               for d in list("0123456789") + ["\u00b9", "\u00b2", "\u00b3"]}


class PathError(ValueError):
    pass


def _ascii_upper(s):
    return "".join(c.upper() if "a" <= c <= "z" else c for c in s)


def _trunc_utf8(s, n):
    b = s.encode()
    if len(b) <= n:
        return s
    return b[:n].decode("utf-8", "ignore")


def sanitize_component(c):
    """One received path component -> a name safe on Windows and macOS (PROTOCOL.md §6.3)."""
    c = "".join("_" if (ord(ch) < 0x20 or ord(ch) == 0x7F or ch in '\\:*?"<>|' or ord(ch) in FORMAT_CHARS) else ch
                for ch in c)
    c = c.rstrip(". ") or "_"
    if _ascii_upper(c.split(".", 1)[0].rstrip(" ")) in RESERVED:
        c = "_" + c
    if len(c.encode()) > FILE_COMPONENT_MAX:
        i = c.rfind(".")
        ext = c[i:] if i > 0 and len(c[i:].encode()) <= 32 else ""
        stem = c[:len(c) - len(ext)]
        c = _trunc_utf8(stem, FILE_COMPONENT_MAX - len(ext.encode())) + ext
        c = c.rstrip(". ") or "_"
    return c


def sanitize_path(p):
    """Wire path -> list of safe components; raises PathError for paths that must be refused."""
    if not p:
        raise PathError("empty path")
    if len(p.encode()) > FILE_PATH_MAX:
        raise PathError("path too long")
    if p[0] in "/\\" or (len(p) >= 2 and p[1] == ":" and p[0].isascii() and p[0].isalpha()):
        raise PathError("absolute path")
    comps = p.split("/")
    if len(comps) > FILE_MAX_DEPTH:
        raise PathError("too deep")
    for c in comps:
        if c == "":
            raise PathError("empty component")
        if c in (".", ".."):
            raise PathError("dot component")
    return [sanitize_component(c) for c in comps]


def with_suffix(name, n, is_dir=False):
    """'a.txt', 2 -> 'a (2).txt' (collision rename; folders and dotfiles get the suffix at the end)."""
    if n <= 1:
        return name
    i = -1 if is_dir else name.rfind(".")
    return f"{name[:i]} ({n}){name[i:]}" if i > 0 else f"{name} ({n})"


def _fstr(s):
    b = s.encode()[:0xFFFF]
    return struct.pack("<H", len(b)) + b


def file_caps(flags, max_total, max_files):
    return bytes([0x70]) + struct.pack("<IQI", flags, max_total, max_files)


def file_offer(tid, entries):
    """entries: [(path, size, mtime_ms)]"""
    out = bytes([0x71]) + struct.pack("<IQI", tid, sum(e[1] for e in entries), len(entries))
    for path, size, mtime in entries:
        out += _fstr(path) + struct.pack("<Qq", size, mtime)
    return out


def file_answer(tid, status, detail=""):
    return bytes([0x72]) + struct.pack("<IB", tid, status) + _fstr(detail)


def file_chunk(tid, index, offset, data):
    return bytes([0x73]) + struct.pack("<IIQ", tid, index, offset) + data


def file_end(tid, index, sha):
    return bytes([0x74]) + struct.pack("<II", tid, index) + sha


def file_ack(tid, nbytes):
    return bytes([0x75]) + struct.pack("<IQ", tid, nbytes)


def file_cancel(tid, reason, detail=""):
    return bytes([0x76]) + struct.pack("<IB", tid, reason) + _fstr(detail)


def file_done(tid, nfiles):
    return bytes([0x77]) + struct.pack("<II", tid, nfiles)


def file_pull():
    return bytes([0x78])


def file_pull_result(status, detail=""):
    return bytes([0x79]) + struct.pack("<B", status) + _fstr(detail)


def file_decode(m):
    """File message (type byte included) -> (name, dict). Raises ValueError/struct.error on bad input."""
    t, b = m[0], m[1:]

    def rstr(p):
        (n,) = struct.unpack_from("<H", b, p)
        if p + 2 + n > len(b):
            raise ValueError("truncated str")
        return b[p + 2:p + 2 + n].decode("utf-8", "replace"), p + 2 + n

    if t == 0x70:
        f, mt, mf = struct.unpack("<IQI", b)
        return "caps", dict(flags=f, max_total=mt, max_files=mf)
    if t == 0x71:
        tid, total, n = struct.unpack_from("<IQI", b)
        p, files = 16, []
        if n > (len(b) - p) // 18:
            raise ValueError("bad file count")
        for _ in range(n):
            path, p = rstr(p)
            size, mtime = struct.unpack_from("<Qq", b, p)
            p += 16
            files.append((path, size, mtime))
        if p != len(b):
            raise ValueError("trailing bytes")
        return "offer", dict(id=tid, total=total, files=files)
    if t in (0x72, 0x76):
        tid, st = struct.unpack_from("<IB", b)
        detail, p = rstr(5)
        return ("answer" if t == 0x72 else "cancel"), dict(id=tid, status=st, detail=detail)
    if t == 0x73:
        tid, idx, off = struct.unpack_from("<IIQ", b)
        return "chunk", dict(id=tid, index=idx, offset=off, data=b[16:])
    if t == 0x74:
        tid, idx = struct.unpack_from("<II", b)
        if len(b) != 40:
            raise ValueError("bad FileEnd length")
        return "end", dict(id=tid, index=idx, sha=b[8:40])
    if t == 0x75:
        tid, nb = struct.unpack("<IQ", b)
        return "ack", dict(id=tid, bytes=nb)
    if t == 0x77:
        tid, nf = struct.unpack("<II", b)
        return "done", dict(id=tid, files=nf)
    if t == 0x78:
        return "pull", {}
    if t == 0x79:
        (st,) = struct.unpack_from("<B", b)
        detail, _ = rstr(1)
        return "pull_result", dict(status=st, detail=detail)
    raise ValueError(f"not a file message: {t:#x}")


def file_vectors():
    """The shared reference encodings (docs/file-transfer-vectors.json "messages")."""
    sha_hello = hashlib.sha256(b"hello").digest()
    return [
        ("FileCaps", file_caps(3, 8 << 30, 10000)),
        ("FileOffer", file_offer(1, [("Photos/a.jpg", 5, 1700000000123), ("b.txt", 0, -1)])),
        ("FileAnswer", file_answer(1, ST_OK)),
        ("FileAnswerDecline", file_answer(0x80000002, ST_TOO_LARGE, "max 1 GiB")),
        ("FileChunk", file_chunk(1, 0, 0, b"hello")),
        ("FileEnd", file_end(1, 0, sha_hello)),
        ("FileAck", file_ack(1, 5)),
        ("FileCancel", file_cancel(0x80000001, ST_CANCELLED, "user")),
        ("FileDone", file_done(1, 2)),
        ("FilePull", file_pull()),
        ("FilePullResult", file_pull_result(ST_NOTHING, "no files")),
    ]


# Adversarial / edge-case names: (wire path, expected components or None = refused).
PATH_VECTORS = [
    ("a.txt", ["a.txt"]),
    ("Photos/2024/IMG 1.jpg", ["Photos", "2024", "IMG 1.jpg"]),
    ("../evil.txt", None),
    ("a/../../evil.txt", None),
    ("./a.txt", None),
    ("a/./b", None),
    ("..", None),
    ("/etc/passwd", None),
    ("\\\\server\\share\\x", None),
    ("\\x", None),
    ("C:\\Windows\\x.dll", None),
    ("c:x.txt", None),
    ("C:/x", None),
    ("a//b", None),
    ("a/", None),
    ("", None),
    ("..\\..\\evil.txt", [".._.._evil.txt"]),
    ("a\\b.txt", ["a_b.txt"]),
    ("x:y.txt", None),
    ("ab:c.txt", ["ab_c.txt"]),
    ("file.txt:Zone.Identifier", ["file.txt_Zone.Identifier"]),
    ("file.txt::$DATA", ["file.txt__$DATA"]),
    ("what?.txt", ["what_.txt"]),
    ("a*b<c>d|e\"f.txt", ["a_b_c_d_e_f.txt"]),
    ("CON", ["_CON"]),
    ("con.txt", ["_con.txt"]),
    ("Con .txt", ["_Con .txt"]),
    ("nul.tar.gz", ["_nul.tar.gz"]),
    ("COM1", ["_COM1"]),
    ("lpt9.log", ["_lpt9.log"]),
    ("COM\u00b9.txt", ["_COM\u00b9.txt"]),
    ("CONIN$", ["_CONIN$"]),
    ("console.txt", ["console.txt"]),
    ("COM10", ["COM10"]),
    ("dir/AUX/x", ["dir", "_AUX", "x"]),
    ("trailing.", ["trailing"]),
    ("trailing ", ["trailing"]),
    ("dots...", ["dots"]),
    ("...", ["_"]),
    (". .", ["_"]),
    ("a/ ../b", ["a", "_", "b"]),
    ("tab\there.txt", ["tab_here.txt"]),
    ("nul\x00byte", ["nul_byte"]),
    ("del\x7f.txt", ["del_.txt"]),
    ("invoice\u202etxt.exe", ["invoice_txt.exe"]),
    ("zero\u200bwidth\ufeff.txt", ["zero_width_.txt"]),
    (".hidden", [".hidden"]),
    ("caf\u00e9/\u65e5\u672c.txt", ["caf\u00e9", "\u65e5\u672c.txt"]),
    ("x" * 250 + ".txt", ["x" * 196 + ".txt"]),
    ("\u65e5" * 100 + ".png", ["\u65e5" * 65 + ".png"]),
    ("y" * 300, ["y" * 200]),
    ("z" * 190 + "." + "e" * 40, ["z" * 190 + "." + "e" * 9]),
    ("/".join(["d"] * 32), ["d"] * 32),
    ("/".join(["d"] * 33), None),
    ("p" * 4097, None),
]

SUFFIX_VECTORS = [
    ("a.txt", 2, False, "a (2).txt"),
    ("archive.tar.gz", 3, False, "archive.tar (3).gz"),
    ("README", 2, False, "README (2)"),
    (".bashrc", 2, False, ".bashrc (2)"),
    ("My.Folder", 2, True, "My.Folder (2)"),
    ("a.txt", 1, False, "a.txt"),
]


def file_vectors_json():
    import json
    j = lambda v: json.dumps(v, ensure_ascii=True)
    rows = lambda items: ",\n".join("  " + j(x) for x in items)
    return ("{\n" + ' "comment": ' + j("Generated by tools/mock_host.py --file-vectors; checked by glide-selftest, "
                                          "cargo test and mock_host.py --selftest (docs/PROTOCOL.md §6). "
                                          "paths: out = sanitized components, null = refused.") + ",\n"
            ' "messages": [\n' + rows({"name": n, "hex": b.hex()} for n, b in file_vectors()) + "\n ],\n"
            ' "paths": [\n' + rows({"in": i, "out": o} for i, o in PATH_VECTORS) + "\n ],\n"
            ' "suffix": [\n' + rows({"name": n, "n": k, "dir": d, "out": o} for n, k, d, o in SUFFIX_VECTORS) + "\n ]\n}\n")


def collect_files(paths):
    """Paths (files or folders) -> [(abs, rel, size, mtime_ms)], skipping symlinks and special files."""
    out = []
    for top in paths:
        top = os.path.abspath(top)
        name = os.path.basename(top.rstrip("/"))
        if os.path.islink(top):
            log(f"files: skipping symlink {top}")
            continue
        if os.path.isdir(top):
            for root, dirs, files in os.walk(top, followlinks=False):
                dirs.sort()
                for f in sorted(files):
                    a = os.path.join(root, f)
                    if os.path.islink(a) or not os.path.isfile(a) or f == ".DS_Store":
                        continue
                    rel = name + "/" + os.path.relpath(a, top).replace(os.sep, "/")
                    st = os.stat(a)
                    out.append((a, rel, st.st_size, int(st.st_mtime * 1000)))
        elif os.path.isfile(top):
            st = os.stat(top)
            out.append((top, name, st.st_size, int(st.st_mtime * 1000)))
    return out


def file_selftest(check):
    import json
    vec_path = os.path.join(HERE, "../docs/file-transfer-vectors.json")
    try:
        disk = open(vec_path).read()
    except OSError:
        disk = ""
    check(disk == file_vectors_json(), "docs/file-transfer-vectors.json is up to date (--file-vectors)")
    for name, b in file_vectors():
        kind, f = file_decode(b)
        re = {
            "caps": lambda: file_caps(f["flags"], f["max_total"], f["max_files"]),
            "offer": lambda: file_offer(f["id"], f["files"]),
            "answer": lambda: file_answer(f["id"], f["status"], f["detail"]),
            "cancel": lambda: file_cancel(f["id"], f["status"], f["detail"]),
            "chunk": lambda: file_chunk(f["id"], f["index"], f["offset"], f["data"]),
            "end": lambda: file_end(f["id"], f["index"], f["sha"]),
            "ack": lambda: file_ack(f["id"], f["bytes"]),
            "done": lambda: file_done(f["id"], f["files"]),
            "pull": lambda: file_pull(),
            "pull_result": lambda: file_pull_result(f["status"], f["detail"]),
        }[kind]()
        check(re == b, f"{name} decode/encode roundtrip")
    bad = 0
    for i, want in PATH_VECTORS:
        try:
            got = sanitize_path(i)
        except PathError:
            got = None
        if got != want:
            bad += 1
            print(f"    path {i[:40]!r}: got {got!r}, want {want!r}")
    check(bad == 0, f"{len(PATH_VECTORS)} path sanitizer vectors")
    check(all(with_suffix(n, k, d) == o for n, k, d, o in SUFFIX_VECTORS), "collision suffix vectors")
    offer = file_vectors()[1][1]
    check(all(_raises(lambda n=n: file_decode(offer[:n])) for n in range(1, len(offer))), "FileOffer truncation rejected")


# ---------------------------------------------------------------- session

class Session:
    def __init__(self, sock, addr, args, streams, password, salt):
        self.sock, self.addr, self.args, self.streams = sock, addr, args, streams
        self.password, self.salt = password, salt
        self.lock = threading.Lock()
        self.send_ctr = 0
        self.recv_ctr = 0
        self.alive = True
        self.restart = threading.Event()
        self.switch_to = None
        self.stats = {"frames": 0, "bytes": 0, "audio_frames": 0}
        self.clip_seq = 0
        self.clipboard = False
        self.audio_enabled = True
        self.audio_need_config = True
        self.files = False
        self.fcond = threading.Condition()
        self.fout = None  # outgoing transfer state (dict)
        self.finc = None  # incoming transfer state (dict)
        self.next_tid = HOST_ID_BIT | 1

    def recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("peer closed")
            buf += chunk
        return bytes(buf)

    def send_msg(self, pt):
        with self.lock:
            nonce = b"\0\0\0\0" + struct.pack("<Q", self.send_ctr)
            self.send_ctr += 1
            ct = self.s2c.encrypt(nonce, pt, b"")
            self.sock.sendall(struct.pack("<I", len(ct)) + ct)

    def recv_msg(self):
        (n,) = struct.unpack("<I", self.recv_exact(4))
        if not (17 <= n <= 32 << 20):
            raise ValueError(f"bad record length {n}")
        ct = self.recv_exact(n)
        nonce = b"\0\0\0\0" + struct.pack("<Q", self.recv_ctr)
        pt = self.c2s.decrypt(nonce, ct, b"")  # raises InvalidTag on failure
        self.recv_ctr += 1
        return pt

    def handshake(self):
        chs = self.recv_exact(54)
        if chs[:4] != b"GLD1" or struct.unpack("<H", chs[4:6])[0] != 1:
            raise ValueError("bad client handshake")
        priv = X25519PrivateKey.generate()
        pub = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        hhs = b"GLD1" + struct.pack("<H", 1) + pub + os.urandom(16) + self.salt
        self.sock.sendall(hhs)
        shared = priv.exchange(X25519PublicKey.from_public_bytes(chs[6:38]))
        pw_key = hashlib.pbkdf2_hmac("sha256", self.password.encode(), self.salt, 100000, 32)
        okm = HKDF(algorithm=hashes.SHA256(), length=64, salt=hashlib.sha256(chs + hhs).digest(),
                   info=b"glide v1 session keys").derive(shared + pw_key)
        self.c2s, self.s2c = ChaCha20Poly1305(okm[:32]), ChaCha20Poly1305(okm[32:])

    def pick_stream(self, caps, mode):
        if mode == 1 and caps & 2 and "hevc444" in self.streams:
            return self.streams["hevc444"]
        if caps & 1 and "hevc" in self.streams:
            return self.streams["hevc"]
        if caps & 4 and "h264" in self.streams:
            return self.streams["h264"]
        raise ValueError(f"no stream for caps={caps:#x}")

    def config_body(self, st):
        return struct.pack("<HHBBBf", st.w, st.h, st.codec, st.chroma, 0, 2.0)

    def send_cursor(self):
        # 24x24 synthetic arrow-ish cursor: white with black border, hotspot top-left.
        w = h = 24
        px = bytearray()
        for y in range(h):
            for x in range(w):
                inside = x <= y and x + y // 2 < 18 and y < 22
                edge = inside and (x == 0 or x == y or x + y // 2 >= 17 or y == 21)
                if edge:
                    px += bytes([0, 0, 0, 255])
                elif inside:
                    px += bytes([255, 255, 255, 255])
                else:
                    px += bytes([0, 0, 0, 0])
        self.send_msg(bytes([0x42]) + struct.pack("<IHHHH", 1, w, h, 0, 0) + bytes(px))
        self.send_msg(bytes([0x41]) + struct.pack("<ffB", 0.5, 0.5, 1))

    def run(self):
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.handshake()
            try:
                hello = self.recv_msg()
            except Exception:
                log(f"{self.addr}: ClientHello decrypt failed (wrong password?) -> closing")
                return
            if hello[0] != 0x01:
                raise ValueError("first message is not ClientHello")
            ver, caps, vw, vh, mode, maxfps = struct.unpack("<HIHHBB", hello[1:13])
            (nl,) = struct.unpack("<H", hello[13:15])
            name = hello[15:15 + nl].decode()
            log(f"{self.addr}: ClientHello v{ver} caps={caps:#05b} view={vw}x{vh} mode={mode} max_fps={maxfps} name={name!r}")
            self.hybrid = mode == 2 and bool(caps & 2) and "hevc444" in self.streams and "hevc" in self.streams
            st = self.streams["hevc"] if self.hybrid else self.pick_stream(caps, mode)
            self.caps = caps
            host = self.args.name.encode()
            self.send_msg(bytes([0x02]) + struct.pack("<H", 1) + struct.pack("<H", len(host)) + host + self.config_body(st))
            if self.hybrid:
                sharp = self.streams["hevc444"]
                self.sharp_idrs = [au for au, k in sharp.aus if k]
                self.send_msg(bytes([0x04]) + self.config_body(sharp))  # SharpLayerConfig
                log(f"{self.addr}: hybrid mode: base {os.path.basename(st.path)} + sharp IDRs from "
                    f"{os.path.basename(sharp.path)} ({len(self.sharp_idrs)} IDRs), period {self.args.hybrid_period} frames")
            if caps & CAP_CLIPBOARD:
                self.clipboard = True
                self.send_msg(clip_caps())
                log(f"{self.addr}: clipboard sync negotiated (sent ClipboardCaps)")
                if self.args.clip_text is not None or self.args.clip_png:
                    threading.Thread(target=self.clip_push_loop, daemon=True).start()
            if caps & CAP_FILES and not self.args.no_files:
                self.files = True
                self.send_msg(file_caps(3, self.args.file_max_total, self.args.file_max_files))
                log(f"{self.addr}: file transfer negotiated (sent FileCaps); receiving into {self.args.file_recv}")
                if self.args.file_send:
                    threading.Thread(target=self.file_send_later, args=(self.args.file_send,), daemon=True).start()
                if self.args.file_evil:
                    threading.Thread(target=self.file_evil, daemon=True).start()
            # DisplayInfo (§3.3): pretend the Mac runs 1920x1080 Retina under "automatic".
            self.display_pref = 0
            self.send_display_info()
            self.send_cursor()
            t = threading.Thread(target=self.video_loop, args=(st,), daemon=True)
            t.start()
            if caps & (1 << 9) and not self.args.no_audio:
                threading.Thread(target=self.audio_loop, daemon=True).start()
            self.input_loop()
        except (EOFError, ConnectionError, OSError) as e:
            log(f"{self.addr}: disconnected ({e})")
        except Exception as e:
            log(f"{self.addr}: error: {type(e).__name__}: {e}")
        finally:
            self.alive = False
            try:
                self.sock.close()
            except OSError:
                pass
            extra = ""
            if "sharp" in self.stats or "rect_frames" in self.stats:
                extra = f" (sharp {self.stats.get('sharp', 0)}, rect frames {self.stats.get('rect_frames', 0)})"
            if self.stats["audio_frames"]:
                extra += f", {self.stats['audio_frames']} audio frames"
            log(f"{self.addr}: session ended; sent {self.stats['frames']} frames{extra}, {self.stats['bytes'] / 1e6:.1f} MB")

    def video_loop(self, st):
        period = 1.0 / self.args.fps
        idx, frame_id = 0, 0
        nxt = time.monotonic()
        last_switch = time.monotonic()
        alt = None
        try:
            while self.alive:
                if self.args.switch_every and time.monotonic() - last_switch > self.args.switch_every:
                    last_switch = time.monotonic()
                    opts = [s for k, s in self.streams.items() if s is not st and (
                        (s.codec == 1 and s.chroma == 0 and self.caps & 1) or
                        (s.codec == 1 and s.chroma == 1 and self.caps & 2) or
                        (s.codec == 2 and self.caps & 4))]
                    if opts:
                        self.switch_to = opts[0]
                if self.switch_to is not None:
                    st, self.switch_to = self.switch_to, None
                    self.send_msg(bytes([0x03]) + self.config_body(st))
                    log(f"{self.addr}: VideoConfig -> {os.path.basename(st.path)}")
                    idx = 0
                if self.restart.is_set():
                    self.restart.clear()
                    idx = 0
                data, key = st.aus[idx]
                flags, rects = (1 if key else 0), b""
                if getattr(self, "hybrid", False):
                    # Cycle: 2/3 full base frames ("moving"), then one sharp 4:4:4 IDR ("settled"),
                    # then base frames limited to small rects (blinking caret / clock).
                    P = self.args.hybrid_period
                    c = frame_id % P
                    if c == (2 * P) // 3:
                        sd = self.sharp_idrs[(frame_id // P) % len(self.sharp_idrs)]
                        self.send_msg(bytes([0x40]) + struct.pack("<IQB", frame_id, mono_us(), 1 | 4) + sd)
                        self.stats["frames"] += 1
                        self.stats["sharp"] = self.stats.get("sharp", 0) + 1
                        self.stats["bytes"] += len(sd)
                        frame_id += 1
                        c += 1
                    if c > (2 * P) // 3 and not key:
                        w, h = st.w, st.h
                        rs = [(64, 64, 256, 64), (w - 320, h - 96, 256, 64)]
                        if c % 2:
                            rs.append((w // 2 - 16, h // 2 - 32, 32, 64))
                        flags |= 8
                        rects = struct.pack("<H", len(rs)) + b"".join(struct.pack("<HHHH", *r) for r in rs)
                        self.stats["rect_frames"] = self.stats.get("rect_frames", 0) + 1
                self.send_msg(bytes([0x40]) + struct.pack("<IQB", frame_id, mono_us(), flags) + rects + data)
                self.stats["frames"] += 1
                self.stats["bytes"] += len(data)
                frame_id += 1
                idx = (idx + 1) % len(st.aus)
                nxt += period
                d = nxt - time.monotonic()
                if d > 0:
                    time.sleep(d)
                else:
                    nxt = time.monotonic()
        except (OSError, EOFError):
            self.alive = False

    def send_clip(self, text=None, png=None):
        self.clip_seq += 1
        self.send_msg(clip_encode(self.clip_seq, text=text, png=png))
        what = (f"text {len(text.encode())} bytes {text[:60]!r}" if text is not None else "") + \
               (f" png {len(png)} bytes" if png is not None else "")
        log(f"{self.addr}: Clipboard -> client seq {self.clip_seq}: {what.strip()}")

    def clip_push_loop(self):
        png = open(self.args.clip_png, "rb").read() if self.args.clip_png else None
        time.sleep(2)
        n = 0
        while self.alive:
            n += 1
            text = self.args.clip_text
            if text is not None and self.args.clip_every:
                text = f"{text} #{n}"  # distinct content each time (identical content is not re-sent)
            try:
                self.send_clip(text=text, png=png)
            except OSError:
                return
            if not self.args.clip_every:
                return
            time.sleep(self.args.clip_every)

    def on_clipboard(self, m):
        try:
            seq, text, png = clip_decode(m)
        except ValueError as e:
            log(f"{self.addr}: bad Clipboard message: {e}")
            return
        if not self.clipboard:
            log(f"{self.addr}: WARNING client sent Clipboard without negotiating caps bit 8")
        parts = []
        if text is not None:
            parts.append(f"text {len(text.encode())} bytes {text[:60]!r}" + (" (CR present!)" if "\r" in text else ""))
        if png is not None:
            parts.append(f"png {len(png)} bytes" + ("" if png.startswith(b"\x89PNG\r\n\x1a\n") else " (NOT a PNG!)"))
            if self.args.clip_save:
                os.makedirs(self.args.clip_save, exist_ok=True)
                path = os.path.join(self.args.clip_save, f"clip-{seq}.png")
                open(path, "wb").write(png)
                parts.append(f"saved {path}")
        log(f"{self.addr}: Clipboard <- client seq {seq}: {', '.join(parts) or 'empty'}")
        if self.args.clip_bounce:
            self.send_clip(text=text, png=png)

    # ------------------------------------------------------------ file transfer (§6)

    def on_file(self, m):
        try:
            kind, f = file_decode(m)
        except (ValueError, struct.error) as e:
            log(f"{self.addr}: files: bad message {m[:1].hex()}: {e}")
            return
        if not self.files:
            log(f"{self.addr}: WARNING client sent a file message without caps bit 11 / FileCaps")
        if kind == "offer":
            self.file_on_offer(f)
        elif kind == "chunk":
            self.file_on_chunk(f)
        elif kind == "end":
            self.file_on_end(f)
        elif kind == "pull":
            if self.args.file_pull:
                log(f"{self.addr}: files: FilePull -> offering {self.args.file_pull}")
                self.send_msg(file_pull_result(ST_OK))
                threading.Thread(target=self.file_send, args=(self.args.file_pull,), daemon=True).start()
            else:
                log(f"{self.addr}: files: FilePull -> nothing to send")
                self.send_msg(file_pull_result(ST_NOTHING, "No files on the Mac clipboard"))
        else:
            if kind == "cancel" and self.finc and self.finc["id"] == f["id"]:
                log(f"{self.addr}: files: <- FileCancel for incoming {f['id']:#x}: reason {f['status']} {f['detail']!r}")
                self.file_abort_incoming()
            with self.fcond:
                if self.fout and self.fout["id"] == f["id"]:
                    self.fout.setdefault("events", []).append((kind, f))
                    if kind == "ack":
                        self.fout["acked"] = f["bytes"]
                    self.fcond.notify_all()
                else:
                    log(f"{self.addr}: files: <- {kind} for unknown transfer {f.get('id', 0):#x} {f}")

    def file_on_offer(self, f):
        tid, files = f["id"], f["files"]
        log(f"{self.addr}: files: <- FileOffer {tid:#x}: {len(files)} files, {f['total']} bytes: "
            + ", ".join(repr(p) for p, _, _ in files[:8]) + (" …" if len(files) > 8 else ""))

        def decline(st, why):
            log(f"{self.addr}: files: -> decline {tid:#x}: status {st} ({why})")
            self.send_msg(file_answer(tid, st, why))

        if tid == 0 or tid & HOST_ID_BIT:
            return decline(ST_PROTOCOL, "transfer id not in the viewer's range")
        if self.finc:
            return decline(ST_BUSY, "another transfer is in progress")
        if self.args.file_decline:
            return decline(ST_DECLINED, "declined (--file-decline)")
        if not files or sum(e[1] for e in files) != f["total"]:
            return decline(ST_PROTOCOL, "bad file list")
        if len(files) > self.args.file_max_files or f["total"] > self.args.file_max_total:
            return decline(ST_TOO_LARGE, "over the mock host's limits")
        rel = []
        for i, (p, _, _) in enumerate(files):
            try:
                rel.append(sanitize_path(p))
            except PathError as e:
                return decline(ST_BAD_NAME, f"file {i + 1}: {e}")
        root = self.args.file_recv
        os.makedirs(root, exist_ok=True)
        self.finc = dict(id=tid, files=files, rel=rel, root=root, next=0, cur=None, got=0, tops={}, saved=[])
        log(f"{self.addr}: files: -> accept {tid:#x}")
        self.send_msg(file_answer(tid, ST_OK))

    def _inc_fail(self, st, why):
        inc = self.finc
        log(f"{self.addr}: files: incoming {inc['id']:#x} failed: status {st} ({why}) -> FileCancel")
        self.send_msg(file_cancel(inc["id"], st, why))
        self.file_abort_incoming()

    def file_abort_incoming(self):
        inc, self.finc = self.finc, None
        if inc and inc["cur"]:
            inc["cur"]["fh"].close()
            try:
                os.unlink(inc["cur"]["tmp"])
            except OSError:
                pass

    def _inc_dir(self, inc, comps):
        """Directory for a file: a fresh top-level folder per transfer (never merged into an existing one)."""
        if len(comps) == 1:
            return inc["root"]
        top = comps[0]
        if top not in inc["tops"]:
            n = 1
            while True:
                cand = with_suffix(top, n, True)
                try:
                    os.mkdir(os.path.join(inc["root"], cand))
                    inc["tops"][top] = cand
                    inc["saved"].append(os.path.join(inc["root"], cand))
                    break
                except FileExistsError:
                    n += 1
        d = os.path.join(inc["root"], inc["tops"][top], *comps[1:-1])
        os.makedirs(d, exist_ok=True)
        return d

    def _inc_open(self, inc, index):
        d = self._inc_dir(inc, inc["rel"][index])
        tmp = os.path.join(d, f".glide-{inc['id']:08x}-{index}.part")
        inc["cur"] = dict(index=index, tmp=tmp, dir=d, fh=open(tmp, "xb"), n=0, h=hashlib.sha256())

    def file_on_chunk(self, f):
        inc = self.finc
        if not inc or inc["id"] != f["id"]:
            return  # late chunk of a cancelled transfer: ignore
        idx = f["index"]
        if idx != inc["next"] or idx >= len(inc["files"]):
            return self._inc_fail(ST_PROTOCOL, f"chunk for file {idx}, expected {inc['next']}")
        if inc["cur"] is None:
            self._inc_open(inc, idx)
        cur = inc["cur"]
        size = inc["files"][idx][1]
        if f["offset"] != cur["n"] or cur["n"] + len(f["data"]) > size or not f["data"] or len(f["data"]) > FILE_CHUNK_MAX:
            return self._inc_fail(ST_PROTOCOL, f"bad chunk offset {f['offset']} / length {len(f['data'])}")
        cur["fh"].write(f["data"])
        cur["h"].update(f["data"])
        cur["n"] += len(f["data"])
        inc["got"] += len(f["data"])
        self.send_msg(file_ack(inc["id"], inc["got"]))

    def file_on_end(self, f):
        inc = self.finc
        if not inc or inc["id"] != f["id"]:
            return
        idx = f["index"]
        if idx != inc["next"]:
            return self._inc_fail(ST_PROTOCOL, f"FileEnd for file {idx}, expected {inc['next']}")
        if inc["cur"] is None:
            self._inc_open(inc, idx)  # empty file
        cur = inc["cur"]
        path, size, mtime = inc["files"][idx]
        cur["fh"].close()
        if cur["n"] != size or cur["h"].digest() != f["sha"]:
            return self._inc_fail(ST_VERIFY, f"file {idx} ({path}): size/SHA-256 mismatch")
        if 1 <= mtime <= 253402300799999:  # PROTOCOL.md §6.2: other values are ignored
            os.utime(cur["tmp"], (mtime / 1000, mtime / 1000))
        name, n = inc["rel"][idx][-1], 1
        while True:  # never overwrite: reserve the name, then move the verified file over it
            final = os.path.join(cur["dir"], with_suffix(name, n))
            try:
                os.close(os.open(final, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
                break
            except FileExistsError:
                n += 1
        os.replace(cur["tmp"], final)
        if len(inc["rel"][idx]) == 1:
            inc["saved"].append(final)
        log(f"{self.addr}: files: saved {final} ({size} bytes, sha256 {cur['h'].hexdigest()} verified)")
        inc["cur"] = None
        inc["next"] += 1
        self.send_msg(file_ack(inc["id"], inc["got"]))
        if inc["next"] == len(inc["files"]):
            log(f"{self.addr}: files: incoming {inc['id']:#x} complete: {len(inc['files'])} files -> FileDone")
            self.send_msg(file_done(inc["id"], len(inc["files"])))
            self.finc = None

    def file_send_later(self, paths):
        time.sleep(2)
        self.file_send(paths)

    def file_send(self, paths):
        items = collect_files(paths)
        if not items:
            log(f"{self.addr}: files: nothing to send in {paths}")
            return
        entries = [(rel, size, mtime, (lambda a=a: open(a, "rb"))) for a, rel, size, mtime in items]
        self.file_transfer(entries)

    def file_transfer(self, entries, corrupt=False, chunk=FILE_CHUNK_MAX, expect=None):
        """entries: [(rel, size, mtime_ms, opener)]. Returns the final event kind ('done', 'answer', 'cancel', ...)."""
        with self.fcond:
            tid = self.next_tid
            self.next_tid += 1
            self.fout = dict(id=tid, acked=0, events=[])
        total = sum(e[1] for e in entries)
        log(f"{self.addr}: files: -> FileOffer {tid:#x}: {len(entries)} files, {total} bytes")
        self.send_msg(file_offer(tid, [(r, s, m) for r, s, m, _ in entries]))

        def wait_event(kinds, timeout=30):
            end = time.monotonic() + timeout
            with self.fcond:
                while self.alive:
                    ev = self.fout["events"]
                    for i, (k, f) in enumerate(ev):
                        if k in kinds or k == "cancel":
                            del ev[i]
                            return k, f
                    left = end - time.monotonic()
                    if left <= 0:
                        return "timeout", {}
                    self.fcond.wait(left)
            return "closed", {}

        k, f = wait_event(("answer",))
        if k != "answer" or f["status"] != ST_OK:
            log(f"{self.addr}: files: offer {tid:#x} not accepted: {k} {f}")
            self.fout = None
            return k if k != "answer" else f"declined:{f['status']}"
        t0, sent = time.monotonic(), 0
        for idx, (rel, size, mtime, opener) in enumerate(entries):
            h, off = hashlib.sha256(), 0
            with opener() as fh:
                while off < size:
                    data = fh.read(min(chunk, size - off))
                    if not data:
                        log(f"{self.addr}: files: {rel} shrank while reading -> cancel")
                        self.send_msg(file_cancel(tid, ST_SOURCE_CHANGED, rel))
                        return "source-changed"
                    with self.fcond:  # flow control: ≤ FILE_SEND_WINDOW unacknowledged
                        while self.alive and sent - self.fout["acked"] > FILE_SEND_WINDOW - len(data):
                            if any(k == "cancel" for k, _ in self.fout["events"]):
                                break
                            self.fcond.wait(1)
                        if any(k == "cancel" for k, _ in self.fout["events"]):
                            k, f = wait_event(())
                            log(f"{self.addr}: files: receiver cancelled {tid:#x}: {f}")
                            self.fout = None
                            return "cancel"
                    self.send_msg(file_chunk(tid, idx, off, data))
                    h.update(data)
                    off += len(data)
                    sent += len(data)
            sha = h.digest()
            if corrupt:
                sha = bytes([sha[0] ^ 0xFF]) + sha[1:]
            self.send_msg(file_end(tid, idx, sha))
        k, f = wait_event(("done",), timeout=60)
        dt = time.monotonic() - t0
        log(f"{self.addr}: files: outgoing {tid:#x} finished: {k} {f} ({sent / 1e6:.1f} MB in {dt:.2f} s, "
            f"{sent * 8 / 1e6 / max(dt, 1e-6):.0f} Mbit/s)")
        self.fout = None
        return k

    def file_evil(self):
        """Adversarial offers to the viewer; logs what it did with each (check the viewer's folder)."""
        time.sleep(2)
        now = int(time.time() * 1000)
        mem = lambda b: (lambda: __import__("io").BytesIO(b))
        res = self.file_transfer([("../escape.txt", 4, now, mem(b"evil"))])
        log(f"{self.addr}: files: EVIL traversal offer -> {res} (want declined:{ST_BAD_NAME})")
        res = self.file_transfer([("C:\\Windows\\evil.dll", 4, now, mem(b"evil"))])
        log(f"{self.addr}: files: EVIL absolute offer -> {res} (want declined:{ST_BAD_NAME})")
        names = ["CON.txt", "ab:cd.txt", "invoice\u202etxt.exe", "trailing. ", "evil/x.txt", "evil/X.txt",
                 "evil/sub/file.txt:Zone.Identifier", "nul"]
        res = self.file_transfer([(n, len(n), now, mem(n.encode())) for n in names])
        log(f"{self.addr}: files: EVIL names offer -> {res} (want done; names sanitized)")
        res = self.file_transfer([("corrupt.bin", 300000, now, mem(os.urandom(300000)))], corrupt=True)
        log(f"{self.addr}: files: EVIL bad SHA-256 -> {res} (want cancel {ST_VERIFY}, no corrupt.bin left)")
        res = self.file_transfer([("huge.bin", 1 << 50, now, mem(b""))])
        log(f"{self.addr}: files: EVIL 1 PiB offer -> {res} (want declined:{ST_TOO_LARGE})")
        res = self.file_transfer([("dup", 1, now, mem(b"1")), ("dup/inner.txt", 1, now, mem(b"2"))])
        log(f"{self.addr}: files: EVIL file/folder clash -> {res} (want declined:{ST_BAD_NAME})")
        log(f"{self.addr}: files: EVIL sequence finished")

    def audio_loop(self):
        """48 kHz stereo s16le sine, sent as ≤10 ms AudioFrames (docs/PROTOCOL.md §3.2)."""
        a = self.args
        rate, ch, max_frames = 48000, 2, 480
        amp = 32767 * 10 ** (a.audio_db / 20)

        def table(freq):  # one second of the tone (repeats exactly for integer Hz)
            return array.array("h", (int(round(amp * math.sin(2 * math.pi * freq * i / rate))) for i in range(rate)))

        left = table(a.audio_freq)
        right = left if a.audio_right_freq in (None, a.audio_freq) else table(a.audio_right_freq)
        block = a.audio_burst or max_frames  # frames produced per "capture callback"
        host_rate = rate * (1 + a.audio_drift_ppm / 1e6)  # frames per real second (host clock skew)
        log(f"{self.addr}: audio: {a.audio_freq:g} Hz sine at {a.audio_db:g} dBFS, {block}-frame blocks"
            f"{f', drift {a.audio_drift_ppm:+g} ppm' if a.audio_drift_ppm else ''}"
            f"{f', send jitter 0..{a.audio_jitter_ms:g} ms' if a.audio_jitter_ms else ''}")
        on_ms, off_ms = (float(x) for x in a.audio_pattern.split(":")) if a.audio_pattern else (1, 0)
        n, seq = 0, 0
        t0 = time.monotonic()
        try:
            while self.alive:
                # Wait until this block has been "captured" (its last sample is in the past).
                d = t0 + (n + block) / host_rate - time.monotonic()
                if d > 0:
                    time.sleep(d)
                if a.audio_jitter_ms:
                    time.sleep(random.random() * a.audio_jitter_ms / 1000)
                first_us = mono_us() - int((time.monotonic() - (t0 + n / host_rate)) * 1e6)
                quiet = off_ms > 0 and (n * 1000 / rate) % (on_ms + off_ms) >= on_ms
                if self.audio_enabled and not quiet:
                    if self.audio_need_config:
                        self.audio_need_config = False
                        self.send_msg(bytes([0x60]) + struct.pack("<BIBH", 1, rate, ch, max_frames))
                    k = (block + max_frames - 1) // max_frames  # near-equal split, like the Mac host
                    off = 0
                    for i in range(k):
                        m = block // k + (1 if i < block % k else 0)
                        pcm = array.array("h", bytes(4 * m))
                        for j in range(m):
                            idx = (n + off + j) % rate
                            pcm[2 * j] = left[idx]
                            pcm[2 * j + 1] = right[idx]
                        if sys.byteorder != "little":
                            pcm.byteswap()
                        ts = first_us + off * 1_000_000 // rate
                        self.send_msg(bytes([0x61]) + struct.pack("<IQ", seq, ts) + pcm.tobytes())
                        self.stats["audio_frames"] += 1
                        seq = (seq + 1) & 0xFFFFFFFF
                        off += m
                n += block
        except (OSError, EOFError):
            self.alive = False

    DISPLAY_MODES = {0: (1920, 1080, 1), 1: (3840, 2160, 0), 2: (2560, 1440, 1), 3: (1920, 1080, 1), 4: (1920, 1080, 1)}

    def send_display_info(self):
        w, h, hi = self.DISPLAY_MODES.get(self.display_pref, (1920, 1080, 1))
        self.send_msg(bytes([0x05, self.display_pref]) + struct.pack("<HHB", w, h, hi))

    def input_loop(self):
        names = {0x10: "MouseMove", 0x11: "MouseButton", 0x12: "MouseWheel", 0x13: "Key", 0x14: "ReleaseAll",
                 0x20: "RequestKeyframe", 0x21: "SetMode", 0x50: "Clipboard"}
        moves = 0
        while self.alive:
            m = self.recv_msg()
            t = m[0]
            if t == 0x30:
                (ct,) = struct.unpack("<Q", m[1:9])
                self.send_msg(bytes([0x31]) + struct.pack("<QQ", ct, mono_us()))
                if self.args.log_pings:
                    # One-way delay up to a constant clock offset: the excess over the minimum is
                    # queueing (e.g. behind file chunks on the viewer's uplink).
                    owd = mono_us() - ct
                    self.min_owd = min(getattr(self, "min_owd", owd), owd)
                    busy = "during file transfer" if self.finc else "idle"
                    log(f"{self.addr}: ping queueing +{(owd - self.min_owd) / 1000:.2f} ms ({busy})")
                continue
            if t == 0x10:
                moves += 1
                if self.args.quiet_input or moves % 30 != 1:
                    continue
                x, y = struct.unpack("<ff", m[1:9])
                log(f"{self.addr}: MouseMove x={x:.4f} y={y:.4f} (logging 1 in 30)")
            elif t == 0x11:
                b, d = m[1], m[2]
                log(f"{self.addr}: MouseButton {['L', 'R', 'M', 'back', 'fwd'][b] if b < 5 else b} {'down' if d else 'up'}")
            elif t == 0x12:
                dx, dy = struct.unpack("<ff", m[1:9])
                log(f"{self.addr}: MouseWheel dx={dx:+.3f} dy={dy:+.3f}")
            elif t == 0x13:
                (u,) = struct.unpack("<H", m[1:3])
                log(f"{self.addr}: Key usage=0x{u:02X} {'down' if m[3] else 'up'}")
            elif t == 0x15:
                vw, vh = struct.unpack("<HH", m[1:5])
                log(f"{self.addr}: ViewSize {vw}x{vh}")
            elif t == 0x16:
                names16 = ["automatic", "crisp", "smooth", "retina", "manual"]
                log(f"{self.addr}: SetDisplayPreference {names16[m[1]] if m[1] < 5 else m[1]}")
                if m[1] < 5:
                    self.display_pref = m[1]
                    self.send_display_info()
            elif t == 0x20:
                log(f"{self.addr}: RequestKeyframe -> restarting stream at first keyframe")
                self.restart.set()
            elif t == 0x50:
                self.on_clipboard(m)
            elif 0x70 <= t <= 0x7F:
                self.on_file(m)
            elif t == 0x62:
                on = bool(m[1])
                log(f"{self.addr}: AudioEnable {'on' if on else 'off (muted)'}")
                if on and not self.audio_enabled:
                    self.audio_need_config = True
                self.audio_enabled = on
            elif t == 0x21:
                mode, kbps, fps = struct.unpack("<BIB", m[1:7])
                log(f"{self.addr}: SetMode mode={mode} bitrate={kbps} max_fps={fps}")
                try:
                    self.switch_to = self.pick_stream(self.caps, mode)
                except ValueError as e:
                    log(f"{self.addr}: {e}")
            else:
                log(f"{self.addr}: {names.get(t, hex(t))} {m[1:].hex()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=7421)
    ap.add_argument("--fps", type=float, default=60.0)
    ap.add_argument("--name", default="mock-host")
    ap.add_argument("--hevc", default=os.path.join(HERE, "streams/hevc420_1440p.h265"))
    ap.add_argument("--hevc444", default=os.path.join(HERE, "streams/hevc444_1440p.h265"))
    ap.add_argument("--h264", default=os.path.join(HERE, "streams/h264_1440p.h264"))
    ap.add_argument("--switch-every", type=float, default=0, help="send a VideoConfig switching streams every N s")
    ap.add_argument("--hybrid-period", type=int, default=60,
                    help="hybrid mode (ClientHello mode 2): frames per cycle; a sharp 4:4:4 IDR at 2/3, rect-only base frames after")
    ap.add_argument("--quiet-input", action="store_true")
    ap.add_argument("--no-audio", action="store_true", help="don't stream audio even if the client supports it")
    ap.add_argument("--audio-freq", type=float, default=440.0, help="test tone frequency (Hz), left channel")
    ap.add_argument("--audio-right-freq", type=float, default=None, help="right channel frequency (default: same as left)")
    ap.add_argument("--audio-db", type=float, default=-12.0, help="tone level in dBFS (default -12)")
    ap.add_argument("--audio-burst", type=int, default=0,
                    help="frames per capture block (e.g. 1024 like ScreenCaptureKit); default 480 = 10 ms")
    ap.add_argument("--audio-drift-ppm", type=float, default=0.0, help="host audio clock error vs real time (ppm)")
    ap.add_argument("--audio-jitter-ms", type=float, default=0.0, help="random 0..N ms delay before each block is sent")
    ap.add_argument("--audio-pattern", metavar="ON_MS:OFF_MS", help="send audio ON_MS, then nothing for OFF_MS (silence gaps)")
    ap.add_argument("--connect", metavar="HOST:PORT",
                    help="reverse mode: dial out to a client running `glide-client --listen` (retries; re-dials after each session)")
    ap.add_argument("--once", action="store_true", help="with --connect: exit after one session")
    ap.add_argument("--password-file", default=os.path.join(HERE, "../.dev/password"))
    ap.add_argument("--clip-text", help="clipboard text to push to the client ~2 s after connect")
    ap.add_argument("--clip-png", help="PNG file to push to the client ~2 s after connect")
    ap.add_argument("--clip-every", type=float, default=0, help="repeat the clipboard push every N s (text gets a counter)")
    ap.add_argument("--clip-bounce", action="store_true", help="send every received clipboard back once (echo test)")
    ap.add_argument("--clip-save", metavar="DIR", help="save received clipboard PNGs here")
    ap.add_argument("--selftest", action="store_true",
                    help="check the clipboard/file codecs against PROTOCOL.md §5/§6 + docs/file-transfer-vectors.json and exit")
    ap.add_argument("--file-vectors", metavar="OUT", help="write docs/file-transfer-vectors.json to OUT and exit")
    ap.add_argument("--no-files", action="store_true", help="don't negotiate file transfer (caps bit 11)")
    ap.add_argument("--file-recv", default=os.path.join(HERE, "../.dev/mock-recv"), help="save files from the viewer here")
    ap.add_argument("--file-send", nargs="+", metavar="PATH", help="offer these files/folders to the viewer ~2 s after connect")
    ap.add_argument("--file-pull", nargs="+", metavar="PATH", help="answer the viewer's FilePull (Ctrl+Alt+Shift+V) with these")
    ap.add_argument("--file-decline", action="store_true", help="decline every offer from the viewer")
    ap.add_argument("--file-evil", action="store_true", help="send adversarial offers (traversal, reserved names, bad SHA-256)")
    ap.add_argument("--file-max-total", type=int, default=8 << 30)
    ap.add_argument("--log-pings", action="store_true", help="log each Ping's queueing delay (input-priority check during transfers)")
    ap.add_argument("--file-max-files", type=int, default=10000)
    args = ap.parse_args()
    if args.selftest:
        sys.exit(0 if selftest() else 1)
    if args.file_vectors:
        open(args.file_vectors, "w").write(file_vectors_json())
        sys.exit(0)

    password = os.environ.get("GLIDE_PASSWORD")
    if not password and os.path.exists(args.password_file):
        password = open(args.password_file).read().strip()
    if not password:
        sys.exit("set GLIDE_PASSWORD or provide --password-file")
    salt = hashlib.sha256(b"glide-mock-host-salt" + args.name.encode()).digest()[:16]  # persistent per host name

    streams = {}
    for key, path, codec, chroma in (("hevc", args.hevc, 1, 0), ("hevc444", args.hevc444, 1, 1), ("h264", args.h264, 2, 0)):
        if path and os.path.exists(path):
            streams[key] = Stream(path, codec, chroma)
    if not streams:
        sys.exit("no streams found; run tools/make_streams.sh")

    if args.connect:
        h, _, p = args.connect.rpartition(":")
        log(f"reverse mode: dialing {h}:{p}")
        while True:
            try:
                s = socket.create_connection((h, int(p)), timeout=3)
                s.settimeout(None)
            except OSError:
                time.sleep(1)
                continue
            a = f"{h}:{p}"
            log(f"{a}: connected (outbound)")
            Session(s, a, args, streams, password, salt).run()
            if args.once:
                return
            time.sleep(1)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(4)
    log(f"mock host listening on {args.bind}:{args.port} ({args.fps:g} fps)")
    while True:
        s, addr = srv.accept()
        a = f"{addr[0]}:{addr[1]}"
        log(f"{a}: connected")
        threading.Thread(target=Session(s, a, args, streams, password, salt).run, daemon=True).start()


if __name__ == "__main__":
    main()
