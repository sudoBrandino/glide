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
- --selftest checks the clipboard codec against the PROTOCOL.md §5 reference bytes (and the §3.3
  latency messages + the docs/LATENCY.md block code) and exits.
- Latency (§3.3): after the client's LatencyEnable (0x80) every VideoFrame is followed by a
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
  GLIDE_PASSWORD=... python3 tools/mock_host.py [--port 7421 | --connect HOST:PORT [--once]] [--fps 60]
      [--hevc streams/hevc420_1440p.h265] [--hevc444 streams/hevc444_1440p.h265]
      [--h264 streams/h264_1440p.h264] [--switch-every SECONDS] [--quiet-input]
      [--clip-text TEXT | --clip-png FILE] [--clip-every SECONDS] [--clip-bounce] [--clip-save DIR]
      [--no-audio] [--audio-freq HZ] [--audio-right-freq HZ] [--audio-db DBFS] [--audio-burst FRAMES]
      [--audio-drift-ppm PPM] [--audio-jitter-ms MS] [--audio-pattern ON_MS:OFF_MS]
      [--latency-pattern [--pattern-size 1280x720] [--pattern-cell 8]]
  python3 tools/mock_host.py --selftest
Generate streams first with tools/make_streams.sh.
"""
import argparse, array, collections, hashlib, math, os, random, select, socket, struct, subprocess, sys, threading, time
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


# ---------------------------------------------------------------- latency (§3.3, docs/LATENCY.md)

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
            if self.args.latency_pattern:
                self.hybrid = False
                pw, ph = (int(v) for v in self.args.pattern_size.split("x"))
                st = argparse.Namespace(w=pw, h=ph, codec=1, chroma=0, path="latency-pattern (live)")
            else:
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
            elif t == 0x20:
                log(f"{self.addr}: RequestKeyframe -> restarting stream at first keyframe")
                self.restart.set()
            elif t == 0x50:
                self.on_clipboard(m)
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
    ap.add_argument("--password-file", default=os.path.join(HERE, "../.dev/password"))
    ap.add_argument("--clip-text", help="clipboard text to push to the client ~2 s after connect")
    ap.add_argument("--clip-png", help="PNG file to push to the client ~2 s after connect")
    ap.add_argument("--clip-every", type=float, default=0, help="repeat the clipboard push every N s (text gets a counter)")
    ap.add_argument("--clip-bounce", action="store_true", help="send every received clipboard back once (echo test)")
    ap.add_argument("--clip-save", metavar="DIR", help="save received clipboard PNGs here")
    ap.add_argument("--selftest", action="store_true", help="check the clipboard codec against PROTOCOL.md §5 and exit")
    ap.add_argument("--latency-pattern", action="store_true",
                    help="stream a live-encoded block-code clock pattern (docs/LATENCY.md) instead of the files")
    ap.add_argument("--pattern-size", default="1280x720", help="--latency-pattern frame size (default 1280x720)")
    ap.add_argument("--pattern-cell", type=int, default=8, help="--latency-pattern cell size in px (default 8)")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(0 if selftest() else 1)

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
