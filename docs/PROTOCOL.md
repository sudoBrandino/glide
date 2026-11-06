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
| `0x50` | Clipboard | `str text` (reserved, v1.1) |
| `0x62` | AudioEnable | `u8 enabled` — see §3.2 |

`codec_caps` bits: `0` HEVC 4:2:0, `1` HEVC 4:4:4, `2` H.264 4:2:0, `8` clipboard (reserved), `9` audio PCM, `10` audio Opus (reserved) — see §3.2.
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
| `0x50` | Clipboard | `str text` (reserved, v1.1) |
| `0x60` | AudioConfig | see §3.2 |
| `0x61` | AudioFrame | see §3.2 |

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

## 4. Test vectors

`docs/test-vectors.json` (generated by `tools/gen_vectors.py` with Python
`cryptography`) gives fixed keys/nonces/password and the expected `c2s_key`,
`s2c_key`, and the first encrypted record in each direction. Both
implementations must reproduce it byte-for-byte.
