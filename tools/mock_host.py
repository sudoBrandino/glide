#!/usr/bin/env python3
"""Glide v2 mock host (docs/PROTOCOL.md), for testing the Windows client without the Mac host.

- Security v2 (§1–2): Noise XX handshake (tools/glide_noise.py) with its own persistent key
  (--key-file), a paired-viewer list (--paired-file), pairing (--pair SECONDS opens the window;
  the 6-digit code is printed; --pair-confirm yes|no|ask decides the Mac side), and the
  ChaCha20-Poly1305 record layer. A v1 viewer gets the "unsupported version 2" reply;
  --v1-host instead behaves like an old v1 host (reads 54 bytes, closes) to test the viewer's
  error message.
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
- --selftest checks the clipboard codec against the PROTOCOL.md §5 reference bytes (and the §3.4
  latency messages + the docs/LATENCY.md block code, and the §3.5 display messages + identity
  matching against docs/display-vectors.json) and exits.
- Multiple displays (§3.5, client caps bit 13): pretends the Mac has --displays N displays (default 2;
  a built-in panel plus external monitors), sends DisplayList after DisplayInfo and answers
  SelectDisplay with DisplayList + DisplayChanged (the video stream itself does not change).
  --display-unplug-after N drops the selected external display after N s (fallback), and plugs it back
  N s later (restored), to exercise the viewer's hot-plug handling.
- Latency (§3.4): after the client's LatencyEnable (0x80) every VideoFrame is followed by a
  FrameTiming (0x81) with the mock's send stamps; LatencyReports (0x82) are logged.
  --latency-pattern streams a live-encoded (ffmpeg, x265 zerolatency) test pattern instead of the
  files: each frame carries the mock's clock as a block code (docs/LATENCY.md), so a viewer in
  --latency-test mode can check its instrumentation against ground truth.
- Hybrid (mode 2, needs HEVC 4:4:4 cap): ServerHello + SharpLayerConfig, base 4:2:0 stream, a
  sharp-layer 4:4:4 IDR (flags bit2) each --hybrid-period frames, and rect-only base frames (bit3).
- Audio (§3.2, client caps bit 9): AudioConfig + a continuous sine (default 440 Hz, -12 dBFS,
  48 kHz stereo) as ≤10 ms AudioFrames. Any glitch (drop, underrun, click) is easy to hear on a
  pure tone. --audio-burst 1024 mimics ScreenCaptureKit's buffer size, --audio-drift-ppm a host
  clock running fast/slow, --audio-jitter-ms random send delay, --audio-pattern 2000:1000 sends
  nothing for 1 s out of every 3 (like the Mac while silent). AudioEnable(0/1) stops/resumes.

Usage:
  python3 tools/mock_host.py [--port 7421 | --connect HOST:PORT [--once]] [--fps 60]
      [--pair SECONDS] [--pair-confirm yes|no|ask] [--key-file F] [--paired-file F] [--v1-host]
      [--hevc streams/hevc420_1440p.h265] [--hevc444 streams/hevc444_1440p.h265]
      [--h264 streams/h264_1440p.h264] [--switch-every SECONDS] [--quiet-input]
      [--clip-text TEXT | --clip-png FILE] [--clip-every SECONDS] [--clip-bounce] [--clip-save DIR]
      [--no-audio] [--audio-freq HZ] [--audio-right-freq HZ] [--audio-db DBFS] [--audio-burst FRAMES]
      [--audio-drift-ppm PPM] [--audio-jitter-ms MS] [--audio-pattern ON_MS:OFF_MS]
      [--latency-pattern [--pattern-size 1280x720] [--pattern-cell 8]]
  python3 tools/mock_host.py --selftest
Generate streams first with tools/make_streams.sh.
"""
import argparse, array, collections, datetime, hashlib, json, math, os, random, select, socket, struct, subprocess, sys, threading, time
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import glide_noise as gn  # noqa: E402
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


# ---------------------------------------------------------------- latency (§3.4, docs/LATENCY.md)

TIMING_UNKNOWN = 0xFFFFFFFF
BLOCK_SYNC, BLOCK_CELLS, BLOCK_QUIET = 0b10110010, 56, 2
BLOCK_REF = "10110010000100100011010001010110011110000001010100111111"  # value 0x12345678, kind 1, counter 5


def crc8(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def block_bits(value, kind, counter):
    p = struct.pack(">I", value & 0xFFFFFFFF) + bytes([(kind & 15) << 4 | (counter & 15)])
    b = bytes([BLOCK_SYNC]) + p + bytes([crc8(p)])
    return [(b[i // 8] >> (7 - i % 8)) & 1 for i in range(BLOCK_CELLS)]


def frame_timing(frame_id, cap_us, flags, callback, submit, encoded, enqueued, sent):
    def d(t):
        return TIMING_UNKNOWN if t is None else max(0, min(TIMING_UNKNOWN - 1, t - cap_us))
    return bytes([0x81]) + struct.pack("<IQBIIIII", frame_id, cap_us, flags, d(callback), d(submit), d(encoded), d(enqueued), d(sent))


def latency_report_str(m):
    names = ("host", "net", "queue", "decode", "render", "scanout", "total", "ground_truth")
    n, flags = struct.unpack("<HB", m[1:4])
    vals = struct.unpack("<8I", m[4:36])
    parts = [f"{k} {'–' if v == TIMING_UNKNOWN else f'{v / 1000:.1f}'}" for k, v in zip(names, vals)]
    return f"n={n} flags={flags:#x} p50 ms: " + "  ".join(parts)


class PatternEncoder:
    """Live test-pattern stream: draws the mock clock as a block code into raw YUV frames and
    encodes them with ffmpeg/x265 (zerolatency, AUD-delimited). Yields (au, keyframe, gen_us,
    submit_us, encoded_us) per frame."""

    def __init__(self, w, h, fps, cell):
        self.w, self.h, self.fps, self.cell = w, h, fps, cell
        self.out = collections.deque()
        self.cv = threading.Condition()
        self.pending = collections.deque()  # (gen_us, submit_us) in encode order
        self.alive = True
        x265 = "keyint=60:min-keyint=60:bframes=0:repeat-headers=1:aud=1:frame-threads=1:log-level=error"
        self.proc = subprocess.Popen(
            [os.environ.get("FFMPEG", "ffmpeg"), "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", f"{w}x{h}",
             "-r", str(fps), "-i", "-", "-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency",
             "-b:v", "20M", "-x265-params", x265, "-f", "hevc", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        y = bytearray([40]) * (w * h)
        for row in range(0, h, 32):  # faint grid so the background is not flat
            y[row * w:(row + 1) * w] = bytes([56]) * w
        self.bg_y = bytes(y)
        self.chroma = bytes([128]) * (w // 2 * h // 2 * 2)
        threading.Thread(target=self._gen, daemon=True).start()
        threading.Thread(target=self._read, daemon=True).start()

    def frame(self, value, counter, t):
        w, cell = self.w, self.cell
        y = bytearray(self.bg_y)
        ox, oy = 64, 64
        pw, ph = (BLOCK_CELLS + 2 * BLOCK_QUIET) * cell, 4 * cell
        for r in range(ph):
            y[(oy + r) * w + ox:(oy + r) * w + ox + pw] = bytes(pw)
        row = bytearray(pw)
        for i, bit in enumerate(block_bits(value, 2, counter)):  # kind 2 = KIND_FRAME
            if bit:
                x = (BLOCK_QUIET + i) * cell
                row[x:x + cell] = b"\xeb" * cell
        for r in range(cell, 3 * cell):
            y[(oy + r) * w + ox:(oy + r) * w + ox + pw] = row
        # A moving box, so there is motion elsewhere too.
        bx = int((t * 400) % (w - 200)) + 100
        for r in range(oy + ph + 40, min(self.h, oy + ph + 140)):
            y[r * w + bx:r * w + bx + 96] = b"\xc0" * 96
        return bytes(y) + self.chroma

    def _gen(self):
        period, nxt, counter = 1.0 / self.fps, time.monotonic(), 0
        try:
            while self.alive:
                gen = mono_us()
                data = self.frame(gen & 0xFFFFFFFF, counter, time.monotonic())
                counter += 1
                with self.cv:
                    self.pending.append((gen, mono_us()))
                self.proc.stdin.write(data)
                nxt += period
                d = nxt - time.monotonic()
                if d > 0:
                    time.sleep(d)
                else:
                    nxt = time.monotonic()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def _read(self):
        fd, buf, aud = self.proc.stdout.fileno(), b"", b"\x00\x00\x00\x01\x46\x01"
        while self.alive:
            r, _, _ = select.select([fd], [], [], 0.003)
            if r:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    return
                buf += chunk
                # Complete AUs: everything before the last AUD that is not at offset 0.
                while True:
                    i = buf.find(aud, 1)
                    if i < 0:
                        break
                    self._emit(buf[:i])
                    buf = buf[i:]
            elif buf:
                # No more bytes for 3 ms: the encoder finished this AU.
                self._emit(buf)
                buf = b""

    def _emit(self, au):
        done = mono_us()
        key = any(16 <= ((n[0] >> 1) & 0x3F) <= 23 for n in split_nals(au) if n)
        with self.cv:
            if not self.pending:
                return
            gen, sub = self.pending.popleft()
            self.out.append((au, key, gen, sub, done))
            self.cv.notify()

    def next(self, timeout=1.0):
        with self.cv:
            if not self.out:
                self.cv.wait(timeout)
            return self.out.popleft() if self.out else None

    def close(self):
        self.alive = False
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        self.proc.kill()


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
    display_selftest(check)
    check(crc8(b"123456789") == 0xF4, "CRC-8/SMBUS check value")
    check("".join(map(str, block_bits(0x12345678, 1, 5))) == BLOCK_REF, "block code reference bits (docs/LATENCY.md)")
    ft = frame_timing(7, 1_000_000, 1, 1_001_500, 1_001_600, 1_009_800, 1_009_900, 1_010_100)
    check(ft.hex() == "810700000040420f000000000001dc0500004006000048260000ac26000074270000", "FrameTiming reference bytes")
    lr = bytes.fromhex("82780001f82a0000b00400002c0100000807000090010000f41a000060540000ffffffff")
    check(latency_report_str(lr).endswith("total 21.6  ground_truth –"), "LatencyReport decode")
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
        # Step 5: the cut can expose a device name ("CON" + spaces + "x" -> "CON"): check again.
        if _ascii_upper(c.split(".", 1)[0].rstrip(" ")) in RESERVED:
            c = "_" + c
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
    ("CON" + " " * 197 + "xyz", ["_CON"]),
    ("NUL" + " " * 193 + "abcdefgh.txt", ["_NUL" + " " * 193 + ".txt"]),
    ("com1" + "." * 250 + "y", ["_com1" + "." * 194 + "y"]),
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


# ---------------------------------------------------------------- §3.5 multiple displays

CAP_DISPLAYS = 1 << 13
DISP_MAIN, DISP_BUILTIN, DISP_HIDPI, DISP_DEFAULT = 1, 2, 4, 8
REASON_SELECTED, REASON_UNAVAILABLE, REASON_FALLBACK, REASON_RESTORED, REASON_HOST, REASON_DEFAULT = range(6)
DISPLAY_LIST_MAX = 32


def display(id, name, flags=0, x=0, y=0, w=1920, h=1080, pw=None, ph=None, refresh=6000, vendor=0, model=0, serial=0):
    """One DisplayList entry as a dict (field names as in PROTOCOL.md §3.5)."""
    return {"id": id, "flags": flags, "x": x, "y": y, "width": w, "height": h,
            "pixel_width": w if pw is None else pw, "pixel_height": h if ph is None else ph,
            "refresh": refresh, "vendor": vendor, "model": model, "serial": serial, "name": name}


def display_list(streamed, selected, displays):
    out = bytes([0x06]) + struct.pack("<IIB", streamed, selected, len(displays))
    for d in displays:
        out += struct.pack("<IBiiHHHHHIII", d["id"], d["flags"], d["x"], d["y"], d["width"], d["height"],
                           d["pixel_width"], d["pixel_height"], d["refresh"], d["vendor"], d["model"], d["serial"])
        out += _fstr(d["name"])
    return out


def display_changed(display_id, reason, requested):
    return bytes([0x07]) + struct.pack("<IBI", display_id, reason, requested)


def select_display(display_id):
    return bytes([0x1A]) + struct.pack("<I", display_id)


def display_decode(m):
    """DisplayList / DisplayChanged / SelectDisplay -> (kind, dict). Raises ValueError/struct.error."""
    t = m[0]
    if t == 0x1A:
        if len(m) < 5:
            raise ValueError("truncated SelectDisplay")
        return "select", {"id": struct.unpack_from("<I", m, 1)[0]}
    if t == 0x07:
        if len(m) < 10:
            raise ValueError("truncated DisplayChanged")
        i, r, q = struct.unpack_from("<IBI", m, 1)
        return "changed", {"id": i, "reason": r, "requested": q}
    if t != 0x06:
        raise ValueError(f"not a display message: {t:#x}")
    streamed, selected, n = struct.unpack_from("<IIB", m, 1)
    p, ds = 10, []
    keys = ("id", "flags", "x", "y", "width", "height", "pixel_width", "pixel_height", "refresh", "vendor", "model", "serial")
    for _ in range(n):
        d = dict(zip(keys, struct.unpack_from("<IBiiHHHHHIII", m, p)))
        p += 35
        (nl,) = struct.unpack_from("<H", m, p)
        if p + 2 + nl > len(m):
            raise ValueError("truncated display name")
        d["name"] = m[p + 2:p + 2 + nl].decode("utf-8", "replace")
        p += 2 + nl
        ds.append(d)
    return "list", {"streamed": streamed, "selected": selected, "displays": ds}


def display_match(want, displays):
    """PROTOCOL.md §3.5 identity matching: remembered {id, vendor, model, serial, name} -> id or None."""
    same = lambda d: (d["vendor"], d["model"], d["serial"]) == (want["vendor"], want["model"], want["serial"])
    for d in displays:
        if d["id"] == want["id"] and same(d):
            return d["id"]
    if want["serial"] != 0:
        return next((d["id"] for d in displays if same(d)), None)
    cands = [d for d in displays if same(d)]
    if want["vendor"] == 0 and want["model"] == 0:
        cands = [d for d in cands if d["name"] == want["name"]]
    named = [d for d in cands if d["name"] == want["name"]]
    return (named or cands or [{"id": None}])[0]["id"]


APPLE, DELL = 0x0610, 0x10AC
BUILTIN = display(1, "Built-in Retina Display", DISP_MAIN | DISP_BUILTIN | DISP_HIDPI | DISP_DEFAULT,
                  0, 0, 1512, 982, 3024, 1964, 12000, APPLE, 0xA04E, 0)
DELL_A = display(5, "DELL U2723QE", DISP_HIDPI, 1512, -300, 1920, 1080, 3840, 2160, 6000, DELL, 0x4268, 0x31324C4A)
DELL_B = display(6, "DELL U2723QE", 0, 3432, -300, 2560, 1440, 2560, 1440, 5994, DELL, 0x4268, 0x31324C4B)
TWIN_1 = display(7, "LG HDR 4K", 0, -1920, 0, 1920, 1080, refresh=6000, vendor=0x1E6D, model=0x7750)
TWIN_2 = display(8, "LG HDR 4K", 0, -3840, 0, 1920, 1080, refresh=6000, vendor=0x1E6D, model=0x7750)
VIRTUAL = display(9, "Glide Virtual Display", DISP_HIDPI, 0, 982, 1920, 1080, 3840, 2160, 6000)
SIDECAR = display(10, "Sidecar Display", 0, 0, 2062, 1366, 1024)


def display_vectors():
    """The shared reference encodings (docs/display-vectors.json "messages")."""
    return [
        ("SelectDisplay", select_display(2)),
        ("SelectDisplayAutomatic", select_display(0)),
        ("DisplayChanged", display_changed(2, REASON_FALLBACK, 5)),
        ("DisplayChangedUnavailable", display_changed(1, REASON_UNAVAILABLE, 0xDEADBEEF)),
        ("DisplayListBuiltin", display_list(1, 0, [BUILTIN])),
        ("DisplayList", display_list(5, 5, [BUILTIN, VIRTUAL, DELL_A, DELL_B])),
        ("DisplayListEmpty", display_list(3, 0, [])),
        ("DisplayListUnicode", display_list(11, 11, [display(11, "Écran 日本", DISP_MAIN | DISP_DEFAULT, -1, -2, 1, 2, 3, 4, 0, 1, 2, 3)])),
    ]


def ident(d, **kw):
    w = {k: d[k] for k in ("id", "vendor", "model", "serial", "name")}
    w.update(kw)
    return w


MATCH_LIST = [BUILTIN, DELL_A, DELL_B, TWIN_1, TWIN_2, VIRTUAL, SIDECAR]
# (description, remembered identity, expected id or None) against MATCH_LIST.
MATCH_VECTORS = [
    ("same id and identity", ident(DELL_B), 6),
    ("new id, same serial", ident(DELL_A, id=99), 5),
    ("id reused by another display", ident(DELL_A, id=1), 5),
    ("serial gone: other unit of the model is not a match", ident(DELL_A, id=5, serial=0x31324C4C), None),
    ("built-in panel, new id", ident(BUILTIN, id=42), 1),
    ("built-in panel, renamed (other language)", ident(BUILTIN, id=42, name="Integriertes Retina-Display"), 1),
    ("twins without serial: same id wins", ident(TWIN_2), 8),
    ("twins without serial, new id: first in list order", ident(TWIN_2, id=77), 7),
    ("no EDID: matched by name", ident(VIRTUAL, id=31), 9),
    ("no EDID: second unknown display by name", ident(SIDECAR, id=32), 10),
    ("no EDID, name differs: none", ident(VIRTUAL, id=31, name="Other Virtual"), None),
    ("unknown vendor/model: none", ident(DELL_A, id=12, vendor=0x4C2D, model=1, serial=0), None),
    ("same id, different identity, no other match: none", ident(DELL_A, id=7, model=0x1111, serial=0), None),
]


def display_vectors_json():
    import json
    j = lambda v: json.dumps(v, ensure_ascii=True)
    rows = lambda items: ",\n".join("  " + j(x) for x in items)
    return ("{\n" + ' "comment": ' + j("Generated by tools/mock_host.py --display-vectors; checked by glide-selftest, "
                                          "cargo test and mock_host.py --selftest (docs/PROTOCOL.md §3.5). "
                                          "match: remembered identity -> expected id (null = no match) in match_list.") + ",\n"
            ' "messages": [\n' + rows({"name": n, "hex": b.hex()} for n, b in display_vectors()) + "\n ],\n"
            ' "match_list": [\n' + rows(MATCH_LIST) + "\n ],\n"
            ' "match": [\n' + rows({"what": w, "want": i, "expect": e} for w, i, e in MATCH_VECTORS) + "\n ]\n}\n")


def display_selftest(check):
    vec_path = os.path.join(HERE, "../docs/display-vectors.json")
    try:
        disk = open(vec_path).read()
    except OSError:
        disk = ""
    check(disk == display_vectors_json(), "docs/display-vectors.json is up to date (--display-vectors)")
    for name, b in display_vectors():
        kind, f = display_decode(b)
        re = {"select": lambda: select_display(f["id"]),
              "changed": lambda: display_changed(f["id"], f["reason"], f["requested"]),
              "list": lambda: display_list(f["streamed"], f["selected"], f["displays"])}[kind]()
        check(re == b, f"{name} decode/encode roundtrip")
        check(all(_raises(lambda n=n: display_decode(b[:n])) for n in range(1, len(b))), f"{name} truncation rejected")
    bad = [(w, display_match(i, MATCH_LIST), e) for w, i, e in MATCH_VECTORS if display_match(i, MATCH_LIST) != e]
    for w, got, e in bad:
        print(f"    match {w!r}: got {got}, want {e}")
    check(not bad, f"{len(MATCH_VECTORS)} display identity matching vectors")


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

class Trust:
    """Mock host identity + paired viewers + pairing window (docs/PROTOCOL.md §2.3)."""

    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        if os.path.exists(args.key_file):
            self.key = gn.priv_from(bytes.fromhex(open(args.key_file).read().strip()))
        else:
            self.key = X25519PrivateKey.generate()
            fd = os.open(args.key_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            from cryptography.hazmat.primitives import serialization as ser
            raw = self.key.private_bytes(ser.Encoding.Raw, ser.PrivateFormat.Raw, ser.NoEncryption())
            os.write(fd, (raw.hex() + "\n").encode()); os.close(fd)
        self.pub = gn.raw_pub(self.key)
        self.paired = json.load(open(args.paired_file)) if os.path.exists(args.paired_file) else []
        self.pair_until = time.monotonic() + args.pair if args.pair > 0 else 0
        self.pairing_busy = False
        log(f"mock host key {gn.fingerprint(self.pub)}; {len(self.paired)} paired viewer(s); "
            f"pairing window {'open for %d s' % args.pair if args.pair > 0 else 'closed (--pair SECONDS opens it)'}")

    def window_open(self):
        return time.monotonic() < self.pair_until

    def is_paired(self, key):
        with self.lock:
            return any(v["key"] == key.hex() for v in self.paired)

    def add(self, name, key):
        with self.lock:
            self.paired = [v for v in self.paired if v["key"] != key.hex()]
            self.paired.append({"name": name, "key": key.hex(),
                                "paired": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
            json.dump(self.paired, open(self.args.paired_file, "w"), indent=2)
            self.pair_until = 0  # one viewer per window, like the real host

    def confirm(self, code, name):
        mode = self.args.pair_confirm
        if mode == "ask" and sys.stdin.isatty():
            typed = input(f"Viewer {name!r} wants to pair. Type the code shown on the PC: ")
            return typed.replace(" ", "") == f"{code:06d}"
        return mode != "no"


class Session:
    def __init__(self, sock, addr, args, streams, trust):
        self.sock, self.addr, self.args, self.streams = sock, addr, args, streams
        self.trust = trust
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
        self.timing = False

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

    def recv_frame(self):
        (n,) = struct.unpack("<H", self.recv_exact(2))
        if n > gn.MAX_HANDSHAKE_MSG:
            raise ValueError(f"handshake message too large ({n})")
        return self.recv_exact(n)

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
        """v2 handshake + auth phase (docs/PROTOCOL.md §1–2). Returns the ClientHello plaintext,
        or None if the viewer was rejected / the pairing failed."""
        magic = self.recv_exact(4)
        if magic == gn.MAGIC_V1:
            self.recv_exact(50)
            self.sock.sendall(gn.MAGIC_V1 + struct.pack("<H", 2) + bytes(64))
            log(f"{self.addr}: Glide v1 viewer (password protocol) -> told 'unsupported version 2'")
            return None
        if magic != gn.MAGIC_V2:
            raise ValueError(f"bad magic {magic!r}")
        preamble = magic + self.recv_exact(gn.CLIENT_PREAMBLE_LEN - 4)
        hi, lo = struct.unpack("<HH", preamble[4:8])
        msg1 = self.recv_frame()
        if not lo <= gn.VERSION <= hi:
            self.sock.sendall(gn.host_preamble(gn.VERSION, gn.ST_UNSUPPORTED_VERSION))
            log(f"{self.addr}: viewer speaks versions {lo}..{hi}; refused")
            return None
        hs = gn.HandshakeXX(False, self.trust.key, preamble)
        if hs.read_message(msg1) != b"":
            raise ValueError("msg1 payload must be empty")
        n_h = os.urandom(32)
        flags = gn.HOST_FLAG_PAIRING_OPEN if self.trust.window_open() else 0
        self.sock.sendall(gn.host_preamble() + gn.frame(hs.write_message(gn.msg2_payload(flags, n_h))))
        try:
            vflags, n_v, name = gn.parse_msg3_payload(hs.read_message(self.recv_frame()))
        except EOFError:
            log(f"{self.addr}: viewer hung up after msg2 (it has a different host key pinned?)")
            return None
        vkey = hs.rs
        send, recv = hs.split()
        self.s2c, self.c2s = ChaCha20Poly1305(send.k), ChaCha20Poly1305(recv.k)
        fp = gn.fingerprint(vkey)

        def reject(code, why):
            log(f"{self.addr}: {why} -> AuthResult {code}")
            self.send_msg(bytes([gn.MSG_AUTH_RESULT, code]))
            return None

        if vflags & gn.VIEWER_FLAG_PAIR_REQUEST:
            if not self.trust.window_open():
                return reject(gn.AUTH_PAIRING_CLOSED, f"viewer {name!r} ({fp}) asked to pair; window closed")
            if self.trust.pairing_busy:
                return reject(gn.AUTH_BUSY, "another pairing is in progress")
            self.trust.pairing_busy = True
            try:
                code = gn.sas_code(hs.handshake_hash(), n_v, n_h)
                log(f"{self.addr}: PAIRING with {name!r} ({fp}) — code {gn.sas_text(code)}")
                self.send_msg(bytes([gn.MSG_PAIR_REVEAL]) + n_h)
                self.sock.settimeout(90)
                m = self.recv_msg()
                if m[0] != gn.MSG_PAIR_CONFIRM:
                    raise ValueError(f"expected PairConfirm, got {m[0]:#x}")
                if not m[1]:
                    log(f"{self.addr}: the viewer declined the code")
                    return None
                if not self.trust.confirm(code, name):
                    return reject(gn.AUTH_DECLINED, "declined on the (mock) Mac")
                self.trust.add(name, vkey)
                log(f"{self.addr}: paired {name!r} ({fp}); saved to {self.args.paired_file}")
                self.send_msg(bytes([gn.MSG_AUTH_RESULT, gn.AUTH_OK]))
            finally:
                self.trust.pairing_busy = False
                self.sock.settimeout(None)
        elif not self.trust.is_paired(vkey):
            return reject(gn.AUTH_UNKNOWN_VIEWER, f"unknown viewer {name!r} ({fp})")
        hello = self.recv_msg()
        log(f"{self.addr}: viewer {name!r} ({fp}) authenticated")
        return hello

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
            if self.args.v1_host:
                self.recv_exact(54)  # an old v1 host: wrong magic -> close without a word
                log(f"{self.addr}: --v1-host: closing like a v1 host would")
                return
            hello = self.handshake()
            if hello is None:
                return
            if hello[0] != 0x01:
                raise ValueError("first message is not ClientHello")
            ver, caps, vw, vh, mode, maxfps = struct.unpack("<HIHHBB", hello[1:13])
            (nl,) = struct.unpack("<H", hello[13:15])
            name = hello[15:15 + nl].decode()
            log(f"{self.addr}: ClientHello v{ver} caps={caps:#05b} view={vw}x{vh} mode={mode} max_fps={maxfps} name={name!r}")
            self.hybrid = mode == 2 and bool(caps & 2) and "hevc444" in self.streams and "hevc" in self.streams
            if self.args.latency_pattern:
                self.hybrid = False
                pw, ph = (int(v) for v in self.args.pattern_size.split("x"))
                st = argparse.Namespace(w=pw, h=ph, codec=1, chroma=0, path="latency-pattern (live)")
            else:
                st = self.streams["hevc"] if self.hybrid else self.pick_stream(caps, mode)
            self.caps = caps
            host = self.args.name.encode()
            self.send_msg(bytes([0x02]) + struct.pack("<H", 2) + struct.pack("<H", len(host)) + host + self.config_body(st))
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
            if caps & CAP_DISPLAYS:
                self.mock_displays = [BUILTIN, DELL_A, DELL_B, VIRTUAL][:max(1, min(self.args.displays, 4))]
                self.streamed, self.selected = BUILTIN["id"], 0
                self.send_display_list()
                log(f"{self.addr}: display selection negotiated (caps bit 13): {len(self.mock_displays)} displays")
                if self.args.display_unplug_after > 0:
                    threading.Thread(target=self.display_hotplug_loop, daemon=True).start()
            self.send_cursor()
            if self.args.latency_pattern:
                t = threading.Thread(target=self.pattern_loop, daemon=True)
            else:
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
                        cap = mono_us()
                        self.send_frame(frame_id, cap, 1 | 4, sd, cap, cap, cap)
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
                cap = mono_us()
                self.send_frame(frame_id, cap, flags, rects + data, cap, cap, cap)
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

    def send_frame(self, frame_id, cap, flags, payload, callback, submit, encoded):
        enq = mono_us()
        self.send_msg(bytes([0x40]) + struct.pack("<IQB", frame_id, cap, flags) + payload)
        if self.timing:
            self.send_msg(frame_timing(frame_id, cap, flags, callback, submit, encoded, enq, mono_us()))

    def pattern_loop(self):
        a = self.args
        pw, ph = (int(v) for v in a.pattern_size.split("x"))
        enc = PatternEncoder(pw, ph, a.fps, a.pattern_cell)
        log(f"{self.addr}: latency pattern: live x265 {pw}x{ph} @ {a.fps:g} fps, cell {a.pattern_cell}px at (64,64)")
        frame_id = 0
        try:
            while self.alive:
                f = enc.next()
                if f is None:
                    continue
                au, key, gen, sub, done = f
                self.send_frame(frame_id, gen, 1 if key else 0, au, gen, sub, done)
                self.stats["frames"] += 1
                self.stats["bytes"] += len(au)
                frame_id += 1
        except (OSError, EOFError):
            self.alive = False
        finally:
            enc.close()

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

    def send_display_list(self):
        with self.lock:
            ds = list(self.mock_displays)
        self.send_msg(display_list(self.streamed, self.selected, ds))

    def on_select_display(self, did):
        ids = [d["id"] for d in self.mock_displays]
        if did != 0 and did not in ids:
            log(f"{self.addr}: SelectDisplay {did}: no such display")
            self.send_msg(display_changed(self.streamed, REASON_UNAVAILABLE, did))
            return
        self.selected = did
        self.streamed = did or BUILTIN["id"]
        name = next(d["name"] for d in self.mock_displays if d["id"] == self.streamed)
        log(f"{self.addr}: SelectDisplay {did or 'automatic'} -> streaming {self.streamed} {name!r} (video unchanged)")
        self.send_display_list()
        self.send_msg(display_changed(self.streamed, REASON_SELECTED, did))

    def display_hotplug_loop(self):
        n = self.args.display_unplug_after
        while self.alive:
            time.sleep(n)
            sel = next((d for d in self.mock_displays if d["id"] == self.selected and not d["flags"] & DISP_BUILTIN), None)
            if sel is None:
                continue
            log(f"{self.addr}: hot-plug: unplugging {sel['name']!r} ({sel['id']})")
            with self.lock:
                self.mock_displays = [d for d in self.mock_displays if d is not sel]
            self.streamed = BUILTIN["id"]
            self.send_display_list()
            self.send_msg(display_changed(self.streamed, REASON_FALLBACK, sel["id"]))
            time.sleep(n)
            back = dict(sel, id=sel["id"] + 100)  # comes back under a new id
            log(f"{self.addr}: hot-plug: {sel['name']!r} is back as {back['id']}")
            with self.lock:
                self.mock_displays = sorted(self.mock_displays + [back], key=lambda d: (d["x"], d["y"], d["id"]))
            self.selected = self.streamed = back["id"]
            self.send_display_list()
            self.send_msg(display_changed(self.streamed, REASON_RESTORED, back["id"]))

    def input_loop(self):
        def input_ok(vals, limit):
            # PROTOCOL.md §3: NaN/inf, |coordinate| > 1000 or |wheel| > 10000 notches is malformed.
            return all(math.isfinite(v) and abs(v) <= limit for v in vals)

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
                if not input_ok((x, y), 1000):
                    log(f"{self.addr}: malformed MouseMove {m.hex()} dropped (§3)")
                    continue
                log(f"{self.addr}: MouseMove x={x:.4f} y={y:.4f} (logging 1 in 30)")
            elif t == 0x11:
                b, d = m[1], m[2]
                log(f"{self.addr}: MouseButton {['L', 'R', 'M', 'back', 'fwd'][b] if b < 5 else b} {'down' if d else 'up'}")
            elif t == 0x12:
                dx, dy = struct.unpack("<ff", m[1:9])
                if not input_ok((dx, dy), 10000):
                    log(f"{self.addr}: malformed MouseWheel {m.hex()} dropped (§3)")
                    continue
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
            elif t == 0x1A:
                if len(m) >= 5 and getattr(self, "mock_displays", None):
                    self.on_select_display(struct.unpack_from("<I", m, 1)[0])
                else:
                    log(f"{self.addr}: SelectDisplay ignored (no DisplayList sent)")
            elif t == 0x20:
                log(f"{self.addr}: RequestKeyframe -> restarting stream at first keyframe")
                self.restart.set()
            elif t == 0x50:
                self.on_clipboard(m)
            elif 0x70 <= t <= 0x7F:
                self.on_file(m)
            elif t == 0x80:
                self.timing = bool(m[1] & 1)
                log(f"{self.addr}: LatencyEnable {m[1]:#x} -> FrameTiming {'on' if self.timing else 'off'}")
            elif t == 0x82:
                log(f"{self.addr}: LatencyReport {latency_report_str(m)}")
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
    ap.add_argument("--key-file", default=os.path.join(HERE, ".mock-host-key"), help="mock host private key (created if missing)")
    ap.add_argument("--paired-file", default=os.path.join(HERE, ".mock-paired.json"), help="paired viewers (JSON list)")
    ap.add_argument("--pair", type=float, default=0, metavar="SECONDS", help="open the pairing window for N seconds at start")
    ap.add_argument("--pair-confirm", choices=["yes", "no", "ask"], default="ask",
                    help="the (mock) Mac user's answer to a pairing code; ask = type the code on this terminal (yes if not a tty)")
    ap.add_argument("--v1-host", action="store_true", help="behave like an old v1 host (read 54 bytes, close)")
    ap.add_argument("--clip-text", help="clipboard text to push to the client ~2 s after connect")
    ap.add_argument("--clip-png", help="PNG file to push to the client ~2 s after connect")
    ap.add_argument("--clip-every", type=float, default=0, help="repeat the clipboard push every N s (text gets a counter)")
    ap.add_argument("--clip-bounce", action="store_true", help="send every received clipboard back once (echo test)")
    ap.add_argument("--clip-save", metavar="DIR", help="save received clipboard PNGs here")
    ap.add_argument("--selftest", action="store_true",
                    help="check the clipboard/latency/file codecs (PROTOCOL.md §5/§3.4/§6, docs/file-transfer-vectors.json) and exit")
    ap.add_argument("--file-vectors", metavar="OUT", help="write docs/file-transfer-vectors.json to OUT and exit")
    ap.add_argument("--display-vectors", metavar="OUT", help="write docs/display-vectors.json to OUT and exit")
    ap.add_argument("--displays", type=int, default=2, help="number of Mac displays to pretend (§3.5, caps bit 13; 1-4)")
    ap.add_argument("--display-unplug-after", type=float, default=0, metavar="SECONDS",
                    help="unplug the selected external display after N s, plug it back N s later (§3.5 hot-plug)")
    ap.add_argument("--no-files", action="store_true", help="don't negotiate file transfer (caps bit 11)")
    ap.add_argument("--file-recv", default=os.path.join(HERE, "../.dev/mock-recv"), help="save files from the viewer here")
    ap.add_argument("--file-send", nargs="+", metavar="PATH", help="offer these files/folders to the viewer ~2 s after connect")
    ap.add_argument("--file-pull", nargs="+", metavar="PATH", help="answer the viewer's FilePull (Ctrl+Alt+Shift+V) with these")
    ap.add_argument("--file-decline", action="store_true", help="decline every offer from the viewer")
    ap.add_argument("--file-evil", action="store_true", help="send adversarial offers (traversal, reserved names, bad SHA-256)")
    ap.add_argument("--file-max-total", type=int, default=8 << 30)
    ap.add_argument("--log-pings", action="store_true", help="log each Ping's queueing delay (input-priority check during transfers)")
    ap.add_argument("--file-max-files", type=int, default=10000)
    ap.add_argument("--latency-pattern", action="store_true",
                    help="stream a live-encoded block-code clock pattern (docs/LATENCY.md) instead of the files")
    ap.add_argument("--pattern-size", default="1280x720", help="--latency-pattern frame size (default 1280x720)")
    ap.add_argument("--pattern-cell", type=int, default=8, help="--latency-pattern cell size in px (default 8)")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(0 if selftest() else 1)
    if args.file_vectors:
        open(args.file_vectors, "w").write(file_vectors_json())
        sys.exit(0)
    if args.display_vectors:
        open(args.display_vectors, "w").write(display_vectors_json())
        sys.exit(0)

    trust = Trust(args)

    streams = {}
    for key, path, codec, chroma in (("hevc", args.hevc, 1, 0), ("hevc444", args.hevc444, 1, 1), ("h264", args.h264, 2, 0)):
        if path and os.path.exists(path):
            streams[key] = Stream(path, codec, chroma)
    if not streams and not args.latency_pattern:
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
            Session(s, a, args, streams, trust).run()
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
        threading.Thread(target=Session(s, a, args, streams, trust).run, daemon=True).start()


if __name__ == "__main__":
    main()
