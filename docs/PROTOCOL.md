# Glide wire protocol — v1 (LAN prototype)

Status: draft, implemented by `mac/` (host) and `windows/` (client).
Everything here is normative; if code and this file disagree, fix one of them.

## Conventions

- All integers are **little-endian**. `f32` is IEEE-754 little-endian.
- `str` = `u16 byte_length` + UTF-8 bytes.
- "Host" = the Mac being controlled. "Client" = the viewer (Windows).
- Default TCP port: **7420**. Both sides set `TCP_NODELAY`.

## 0. Connection direction

Either side may open the TCP connection; the protocol after connect is identical.

- **Viewer dials** (default): host listens (`glide-host`), viewer connects.
- **Host dials** (`glide-host --connect VIEWER[:PORT]`, viewer runs `--listen`): for networks
  that only allow host→viewer connections (e.g. a locked-down admin VLAN). The host redials
  every 2 s while disconnected.

In both cases the **viewer** sends `ClientHandshake` first.

## 1. Handshake (plaintext)

Client connects and sends `ClientHandshake` (54 bytes):

| off | size | field |
|----|----|----|
| 0 | 4 | magic `"GLD1"` (ASCII) |
| 4 | 2 | `u16` protocol version = 1 |
| 6 | 32 | client X25519 ephemeral public key |
| 38 | 16 | client random nonce |

Host replies with `HostHandshake` (70 bytes):

| off | size | field |
|----|----|----|
| 0 | 4 | magic `"GLD1"` |
| 4 | 2 | `u16` protocol version = 1 |
| 6 | 32 | host X25519 ephemeral public key |
| 38 | 16 | host random nonce |
| 54 | 16 | password salt (persistent per host) |

If magic/version mismatch, the receiver closes the connection.

### Key derivation

```
pw_key     = PBKDF2-HMAC-SHA256(password_utf8, salt, iterations = 100000, dkLen = 32)
shared     = X25519(own_private, peer_public)                       // 32 bytes
transcript = ClientHandshake (54 bytes) || HostHandshake (70 bytes) // 124 bytes
okm        = HKDF-SHA256(ikm  = shared || pw_key,
                         salt = SHA-256(transcript),
                         info = "glide v1 session keys",
                         L    = 64)
c2s_key = okm[0..32]    // client -> host
s2c_key = okm[32..64]   // host -> client
```

The password is never sent. A wrong password yields different keys, so the
host's first decrypt of a client record fails and the host closes the
connection. (Known v1 limitation: an active MITM can mount an offline
dictionary attack against the password. v2 replaces this with SPAKE2 +
pinned host keys.)

## 2. Record layer (encrypted)

After the handshake every message travels as a record:

| size | field |
|----|----|
| 4 | `u32` ciphertext length `L` (includes 16-byte tag), `17 <= L <= 32 MiB` |
| L | ChaCha20-Poly1305 ciphertext + tag |

- Key: `c2s_key` for client→host, `s2c_key` for host→client.
- Nonce (12 bytes): `00 00 00 00` || `u64` little-endian record counter.
  Each direction has its own counter starting at **0**, incremented per record.
- AAD: empty.
- Plaintext: `u8 message_type` || payload.

Any decrypt failure is fatal: close the connection.

## 3. Messages

### Client → Host

| type | name | payload |
|----|----|----|
| `0x01` | ClientHello | `u16 version`, `u32 codec_caps`, `u16 view_w`, `u16 view_h` (physical pixels of the monitor the viewer window is on — not necessarily the primary), `u8 mode`, `u8 max_fps`, `str client_name` |
| `0x10` | MouseMove | `f32 x`, `f32 y` — normalized 0..1 over the host display |
| `0x11` | MouseButton | `u8 button` (0 L, 1 R, 2 M, 3 back, 4 fwd), `u8 down` (1/0) |
| `0x12` | MouseWheel | `f32 dx`, `f32 dy` — in wheel notches (1.0 = one notch, fractional OK). `dy > 0` = wheel pushed away from user (scroll up). `dx > 0` = scroll right |
| `0x13` | Key | `u16 hid_usage` (USB HID Keyboard page 0x07), `u8 down` (1/0). A down for an already-held key is an autorepeat |
| `0x14` | ReleaseAll | (none) — host releases every held key/button |
| `0x15` | ViewSize | `u16 view_w`, `u16 view_h` — physical pixels of the monitor/area the viewer will present on (the window's current monitor in fullscreen). Sent whenever it changes (window moved to another monitor, display mode change). The host re-captures so the encoded width ≤ `view_w` and follows with `VideoConfig` + keyframe |
| `0x20` | RequestKeyframe | (none) |
| `0x21` | SetMode | `u8 mode` (0 fast, 1 sharp), `u32 bitrate_kbps` (0 = auto), `u8 max_fps` (0 = keep) |
| `0x30` | Ping | `u64 client_time_us` |
| `0x50` | Clipboard | clipboard snapshot, see §5 (only after the host sent `ClipboardCaps`) |
| `0x62` | AudioEnable | `u8 enabled` — see §3.2 |
| `0x80` | LatencyEnable | `u8 flags` — see §3.3 |
| `0x82` | LatencyReport | viewer latency breakdown — see §3.3 |

`codec_caps` bits (despite the name, a general capability mask): bits 0–7 are video codecs —
`0` HEVC 4:2:0, `1` HEVC 4:4:4, `2` H.264 4:2:0; bits 8+ are non-video features — `8` clipboard
sync (§5), `9` audio PCM, `10` audio Opus (reserved) (§3.2). Hosts ignore bits they don't know;
codec selection looks at bits 0–7 only.
`mode`: `0` fast (4:2:0 only), `1` sharp (4:4:4 every frame), `2` **hybrid** (4:2:0 while the screen
changes + a 4:4:4 refinement layer once it settles; see §3.1). Hybrid requires `codec_caps` bit 1;
the host falls back to fast otherwise. Viewers that support it should default to hybrid.

Modifier remapping (e.g. Windows Ctrl → Mac Command) is the **client's** job:
the host injects exactly the HID usages it receives.

### Host → Client

| type | name | payload |
|----|----|----|
| `0x02` | ServerHello | `u16 version`, `str host_name`, then a `VideoConfig` body (below) |
| `0x04` | SharpLayerConfig | `VideoConfig` body for the refinement layer (hybrid mode only; sent right after `ServerHello`/`VideoConfig`). Same width/height as the base layer, HEVC 4:4:4 |
| `0x03` | VideoConfig | `u16 width`, `u16 height` (encoded pixels), `u8 codec` (1 HEVC, 2 H.264), `u8 chroma` (0 4:2:0, 1 4:4:4), `u8 color` (0 BT.709 limited), `f32 scale` (host backing scale, e.g. 2.0) |
| `0x31` | Pong | `u64 client_time_us` (echoed), `u64 host_time_us` |
| `0x40` | VideoFrame | `u32 frame_id`, `u64 capture_time_us` (host monotonic), `u8 flags`, [rects], then Annex-B elementary stream bytes. Flags: bit0 keyframe; bit1 refresh (re-encode of unchanged content for quality — `capture_time_us` is the original capture, so exclude from latency stats); bit2 **sharp layer** (decode with the refinement-layer decoder, see §3.1); bit3 **has rects**: the payload starts with `u16 n` then `n` × (`u16 x, y, w, h`) in encoded pixels, before the Annex-B bytes |
| `0x41` | CursorPos | `f32 x`, `f32 y` (normalized), `u8 visible` |
| `0x42` | CursorShape | `u32 shape_id`, `u16 w`, `u16 h`, `u16 hot_x`, `u16 hot_y`, then `w*h*4` bytes BGRA, straight (non-premultiplied) alpha, top-down rows |
| `0x43` | CursorShapeRef | `u32 shape_id` — switch to a previously sent shape |
| `0x50` | Clipboard | clipboard snapshot, see §5 (only to clients with caps bit 8) |
| `0x51` | ClipboardCaps | `u32 formats`, `u32 max_bytes` — see §5 (only to clients with caps bit 8) |
| `0x60` | AudioConfig | see §3.2 (only to clients with caps bit 9) |
| `0x61` | AudioFrame | see §3.2 (only to clients with caps bit 9) |
| `0x81` | FrameTiming | per-frame host timestamps, see §3.3 (only after `LatencyEnable`) |

Rules:
- Host sends `ServerHello` immediately after it successfully decrypts `ClientHello`.
- A `VideoConfig` (or `ServerHello`) always precedes the first `VideoFrame` of a new
  configuration, and the next `VideoFrame` is a keyframe. Client must reset its decoder.
- Keyframes carry VPS/SPS/PPS (HEVC) or SPS/PPS (H.264) in-band, Annex-B with 4-byte start codes.
- No B-frames; decode order == display order. Client should display every frame immediately.
- The host only sends frames when the screen changes; long gaps are normal.
- `CursorShape` sizes are in **host pixels**; client may scale by its own view scale.

## 3.1 Hybrid mode and the viewer canvas

The viewer keeps a **canvas**: an RGB texture the size of the encoded video, which is what it
presents. Two independent decoders feed it:

- **Base layer** (`flags` bit2 = 0): the normal continuous 4:2:0 stream (P-frames reference
  earlier base-layer frames only). Every base frame must be decoded, in order. After decoding:
  - if bit3 (has rects) is set and the frame is not a keyframe, copy **only those rectangles**
    from the decoded frame into the canvas (content outside them is unchanged on the host, and
    the canvas may hold sharper pixels there);
  - otherwise copy the whole frame.
- **Sharp layer** (`flags` bit2 = 1): always a standalone keyframe (IDR, HEVC 4:4:4, format per
  `SharpLayerConfig`). Decode it with a separate decoder and copy the **whole** frame into the canvas.

The host only sends a sharp frame when nothing changed since its capture, and it never sends a
sharp frame whose capture is older than the newest base frame already sent; so "apply in arrival
order" is always correct.

Rects are clamped to the frame, already padded by the host for codec bleed; the viewer applies
them as-is. Hosts MUST align rect edges to multiples of 16 encoded pixels (so 4:2:0 chroma never
straddles a rect edge). A base-layer frame without bit3 is a full update (used for keyframes,
large changes, and modes 0/1). bit3 with `n = 0` means "decode only, leave the canvas unchanged"
(the frame still advances the base decoder's reference chain).

A `VideoConfig` resets the base decoder and the canvas and invalidates the sharp layer; in hybrid
mode the host always follows it with a fresh `SharpLayerConfig`.

## 3.2 Audio (v1.2)

Host system audio (everything the Mac plays, except the host process itself) streamed to the
viewer's speakers. One-way, host → client; lowest latency first.

**Capability.** ClientHello `codec_caps` bit **9** = `AUDIO_PCM`: the viewer can play
`AudioFrame`s with codec 1. Bit **10** = `AUDIO_OPUS` is reserved for codec 2 (not implemented).
A viewer that sets neither bit never receives audio messages; a host without audio support
ignores the bits. (Bits 0–2 are video codecs, bit 8 is reserved for clipboard.)

| dir | type | name | payload |
|----|----|----|----|
| H→C | `0x60` | AudioConfig | `u8 codec` (0 off, 1 PCM s16le, 2 Opus — reserved), `u32 sample_rate` (Hz), `u8 channels`, `u16 frame_samples` (nominal samples per channel per `AudioFrame`; informational) |
| H→C | `0x61` | AudioFrame | `u32 seq`, `u64 capture_time_us` (host monotonic clock — the same clock as `VideoFrame`/`Pong` — of the frame's **first** sample), then the payload. Codec 1: interleaved signed 16-bit little-endian samples, `n × channels × 2` bytes (`n` = payload bytes / (2 × channels)) |
| C→H | `0x62` | AudioEnable | `u8 enabled` — 1 = send audio, 0 = stop sending (viewer muted) |

Rules:
- Audio is **on by default** when the viewer sets bit 9; no `AudioEnable` is needed to start it.
- The host sends `AudioConfig` before the first `AudioFrame`, whenever the format changes, and
  again before the first frame after each `AudioEnable(1)`. An `AudioConfig` starts a new
  audio stream: the viewer flushes its jitter buffer (and reopens its output device if the
  format changed). `codec = 0` means the host has no audio for this session (disabled or capture
  unavailable): the viewer releases its output device.
- Frames carry **at most 10 ms** of audio (≤ 480 samples at 48 kHz) and are sent as soon as
  they are captured (no pacing). The host splits larger capture buffers into near-equal frames.
- `seq` increments by 1 for every frame the host produces, **including frames it drops** (it
  drops audio only when the connection backlog is far beyond the video backpressure limit). A
  gap in `seq` is lost audio; the viewer plays the frames it got back-to-back (it does not
  insert silence for the gap — that would only add latency).
- A payload whose length is not a multiple of `2 × channels` is malformed; the viewer drops it.
- `AudioEnable(0)`: the host stops sending `AudioFrame`s until `AudioEnable(1)`. Muting is the
  viewer's job; the host never changes the Mac's own volume.

Viewer playback (non-normative, what `windows/` does): WASAPI shared-mode, event-driven render
keeping ~16 ms queued in the device (one 10 ms engine period + slack); a jitter buffer that primes to a **30 ms** target, holds that level
by tiny resampling (≤ ±0.2 %) only when it drifts out of a ±8 ms dead band (bit-exact output
otherwise), raises the target by 10 ms per underrun (max 120 ms, decaying back after 20 s
without one), and drops audio outright if it ever holds more than target + 60 ms.

Reference encodings (both implementations test these):

```
AudioConfig {codec 1, 48000 Hz, 2 ch, 480}              60 01 80bb0000 02 e001
AudioFrame  {seq 7, t 1000000 µs, L/R 1,-1, 32767,-32768} 61 07000000 40420f0000000000 0100 ffff ff7f 0080
AudioEnable {0}                                         62 00
```

## 3.3 Latency instrumentation (v1.3)

Message types `0x80–0x8F` are reserved for latency measurement. Everything here is optional and
informational: a peer that doesn't implement it loses nothing but numbers.

| dir | type | name | payload |
|----|----|----|----|
| C→H | `0x80` | LatencyEnable | `u8 flags` — bit0: send `FrameTiming` for every `VideoFrame` (1 = on, 0 = off) |
| H→C | `0x81` | FrameTiming | `u32 frame_id`, `u64 capture_us`, `u8 flags`, then five `u32` offsets in µs after `capture_us`: `callback`, `submit`, `encoded`, `enqueued`, `sent` |
| C→H | `0x82` | LatencyReport | `u16 samples`, `u8 flags`, then eight `u32` µs: `host`, `network`, `queue`, `decode`, `render`, `scanout`, `total`, `ground_truth` |

Rules:
- A viewer that wants timing sends `LatencyEnable(1)` once after `ServerHello` (it is not
  gated by a caps bit; a v1.2 host ignores the unknown message). The host then follows **every**
  `VideoFrame` (base and sharp layer, refresh frames included) with a `FrameTiming` carrying
  the same `frame_id`, sent once the network stack has accepted the whole `VideoFrame` record
  (so it usually arrives right after the frame, possibly after later frames — match by id).
- `FrameTiming` fields (host monotonic clock, the clock of `capture_time_us` and `Pong`):
  `capture_us` = the frame's `capture_time_us` (ScreenCaptureKit presentation time);
  `flags` = the frame's `VideoFrame` flags; `callback` = the capture callback ran;
  `submit` = handed to the encoder; `encoded` = encoder output; `enqueued` = record queued on
  the connection; `sent` = send completion (whole record accepted by the TCP stack — not wire
  time). `0xFFFFFFFF` = not measured. For refresh frames, offsets are relative to the original
  capture and are not latencies.
- `LatencyReport` is the viewer's p50 breakdown over its last ~2 s (definitions in
  `docs/LATENCY.md`); `0xFFFFFFFF` = not measured. `flags` bit0: `total` ends at scan-out
  (else at the `Present()` call); bit1: `ground_truth` is valid (latency test mode). Viewers send
  it at most every 2 s and only after receiving at least one `FrameTiming` (proof that the host
  implements §3.3). The host only logs/displays it.

Reference encodings (Rust, Swift `glide-selftest` and `mock_host.py --selftest` check these):

```
FrameTiming {id 7, capture 1000000, flags 1, callback 1500, submit 1600, encoded 9800, enqueued 9900, sent 10100}
  81 07000000 40420f0000000000 01 dc050000 40060000 48260000 ac260000 74270000
LatencyEnable {1}  80 01
LatencyReport {120 samples, flags 1, host 11000, network 1200, queue 300, decode 1800, render 400,
               scanout 6900, total 21600, ground_truth unknown}
  82 7800 01 f82a0000 b0040000 2c010000 08070000 90010000 f41a0000 60540000 ffffffff
```

The glass-to-glass test pattern (a block code of the host clock drawn on the host screen and
read back by the viewer) is not part of the wire protocol; its layout is in `docs/LATENCY.md`.

## 4. Test vectors

`docs/test-vectors.json` (generated by `tools/gen_vectors.py` with Python
`cryptography`) gives fixed keys/nonces/password and the expected `c2s_key`,
`s2c_key`, and the first encrypted record in each direction. Both
implementations must reproduce it byte-for-byte.

## 5. Clipboard sync (v1.1)

Message types `0x50–0x5F` are reserved for clipboard sync. Text and images sync in both
directions; only changes made while a session is authenticated are sent (connecting does not
push either side's current clipboard to the other).

### Negotiation

1. The client sets `codec_caps` bit 8 in `ClientHello` if it supports clipboard sync.
2. If (and only if) bit 8 is set and the host supports it, the host sends `ClipboardCaps` right
   after `ServerHello`: `u32 formats` (bit0 text, bit1 PNG image), `u32 max_bytes` (the largest
   total item payload it accepts, normally 16 MiB).
3. The client sends `Clipboard` only after it received `ClipboardCaps`, and only formats listed
   there. The host never sends `0x50`/`0x51` to a client without bit 8 (v1.0 viewers parse
   `0x50` with the old reserved `str` layout and would drop the connection).

### `0x50` Clipboard (both directions)

| size | field |
|----|----|
| 4 | `u32 seq` — sender's counter, starts at 1 per connection, +1 per Clipboard message |
| 1 | `u8 count` — number of items |
| … | `count` × item: `u8 format`, `u32 len`, `len` bytes |

Item formats (each at most once; a receiver uses the first and skips duplicates):

| format | content |
|----|----|
| `1` | text: UTF-8, **LF** line endings, no NUL terminator |
| `2` | image: a complete PNG file |

All items of one message describe the same clipboard content (alternative representations); the
receiver replaces its whole clipboard with them. Unknown formats are skipped (forward compatible).
`count = 0` is valid and is ignored. Invalid UTF-8 in a text item is replaced (U+FFFD), not fatal.

Limits: the sum of item `len`s is at most **16 MiB** (`CLIPBOARD_MAX`, also bounded by the peer's
`max_bytes`). A sender never truncates: content over the limit is not sent and the sender logs a
line saying so (a partial paste is worse than none). A receiver ignores (and logs) a message over
its limit.

### Sender rules

- If the clipboard holds text, send the text item only (apps like Excel also put a rendered image
  of the cells there; it is not sent). Otherwise, if it holds an image, send it as PNG.
- Line endings on the wire are LF. Windows converts CRLF → LF when sending and LF → CRLF when
  applying. macOS sends text as-is apart from CRLF → LF.
- macOS skips pasteboards marked `org.nspasteboard.TransientType` or
  `org.nspasteboard.AutoGeneratedType`, and by default `org.nspasteboard.ConcealedType`
  (password managers; nspasteboard.org conventions).
- Windows by default skips content carrying a privacy marker (registered formats):
  `ExcludeClipboardContentFromMonitorProcessing`, `Clipboard Viewer Ignore`, or
  `CanIncludeInClipboardHistory` / `CanUploadToCloudClipboard` holding DWORD 0.
- Skipping logs a line without the content. Opt in to syncing such secrets: host.json
  `"clipboard": {"syncConcealed": true}`; viewer `--clipboard-sync-secrets` or
  `GLIDE_CLIPBOARD_SYNC_SECRETS=1`.

### Receiver rules

- An image item is untrusted: before any decoder sees it, the receiver checks the PNG signature
  and that `IHDR` is the first chunk, and rejects it if width or height is 0 or
  width × height > 64 Mi pixels (decompression bombs). A rejected image is dropped; text in the
  same message is still applied.

### Echo suppression (normative)

A peer that applies a received `Clipboard` to its local clipboard MUST NOT send that change back.
Both implementations use the same guards (`ClipboardEchoGuard` in Swift, `EchoGuard` in Rust):

1. **Change marker** — after writing the clipboard, record the OS change marker (macOS
   `NSPasteboard.changeCount`, Windows `GetClipboardSequenceNumber()`; Windows also checks
   `GetClipboardOwner()` == the viewer window). A local change whose marker equals the recorded
   one is our own write and is not sent.
2. **Content hash** — remember a 64-bit FNV-1a hash of the last content sent *or* applied (the
   UTF-8 text if there is text, else the image bytes — the PNG as received/sent, or the raw
   image data read locally before conversion). Content whose hash equals it is not sent again,
   so a clipboard manager re-writing the same data cannot start a ping-pong. When reading an
   image, both sides prefer an existing PNG representation, so re-reading what was applied
   hashes identically.

3. **Apply check** — a receiver does not rewrite its clipboard with content whose hash equals
   the last content sent/applied while the clipboard's marker is still the one that content was
   read/written at (it is already there; rewriting would only drop richer formats such as
   RTF/HTML that the source app provided).

`seq` is informational (logs, debugging); echo suppression does not depend on it.

### Reference bytes

`Clipboard{seq=1, text "hi\n"}` = `50 01000000 01 01 03000000 68690a`;
`ClipboardCaps{formats=3, max_bytes=16 MiB}` = `51 03000000 00000001`.
Both implementations and `tools/mock_host.py --selftest` check these.
