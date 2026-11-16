# Glide wire protocol — v2

Status: draft, implemented by `mac/` (host) and `windows/` (client).
Everything here is normative; if code and this file disagree, fix one of them.
Security v2 (this document's §1–2) replaced the v1 password handshake; v1 is described at the end
of §2 as "legacy, removed".

## Conventions

- All integers are **little-endian**. `f32` is IEEE-754 little-endian.
- `str` = `u16 byte_length` + UTF-8 bytes.
- "Host" = the machine being controlled. "Client" / "viewer" = the machine in front of the user.
  Glide's original pairing is a Mac host and a Windows viewer; a Windows host and a Mac viewer speak
  the same protocol ([WINDOWS_HOST.md](WINDOWS_HOST.md)). Where this document says "Mac" or "PC" it
  describes the original pairing; the rules apply to the role.
- Default TCP port: **7420**. Both sides set `TCP_NODELAY`.
- `‖` = concatenation. `SHA-256` as in FIPS 180-4.

## 0. Connection direction

Either side may open the TCP connection; the protocol after connect is identical. Both sides
listen and dial at the same time, and whichever direction the network allows connects:

- The **host** listens (port 7420). Once it knows the viewer's address
  (`glide-host --connect VIEWER[:PORT]`, `connect` in host.json, or its setup window) it also
  dials it, redialing every 2 s while disconnected (backing off to 60 s while the viewer keeps
  refusing it, see §2.5). Its dialer stays idle while a viewer that dialed in is connected, and
  while it has no paired viewer and the pairing window is closed (opening the window dials at
  once).
  `"listen": false` (or `--no-listen`) with a viewer address turns listening off.
- The **viewer** given the host's address (command line or config `host`) dials it and also
  listens (config `accept_incoming`, default on; `--no-listen` = dial only). Without an address
  (`--listen [PORT]`, or no `host` in the config) it only listens.
- Dial-only on one side needs listening on the other: for networks that only allow
  host→viewer connections (e.g. a locked-down admin VLAN), the viewer listens and the host dials.

There is one session at a time. Whichever side dialed, the **viewer** writes first and is the
Noise **initiator**; the host is the **responder**.

## 1. Handshake

### 1.1 Overview and design

Each side has a long-term **static X25519 key pair** (its identity). The handshake is
**Noise_XX_25519_ChaChaPoly_SHA256** (Noise Protocol Framework, revision 34): mutual
authentication with both static keys, forward secrecy from ephemeral keys, and the viewer's
static key encrypted to the host. There is no password and nothing derived from a human secret,
so a recorded or actively intercepted handshake gives an attacker nothing to guess offline.

Who may connect is decided by **key pinning** (§2.3): the host keeps the public keys of paired
viewers; the viewer keeps the host's public key per target. Keys get pinned once, by a
**pairing** (§2.4) that both users confirm by comparing a 6-digit code (Short Authentication
String, SAS) bound to the handshake.

Why not a PAKE: v1 mixed a password into the KDF, which hands an active impostor of either side a
value to test guesses against offline. A PAKE (CPace/SPAKE2) fixes that but needs raw curve
arithmetic that CryptoKit doesn't expose. Static keys + pinning + a one-time SAS pairing needs only
X25519/ChaCha20-Poly1305/SHA-256/HMAC, available on both platforms.

Implementations: Swift `mac/Sources/GlideCore/{Noise,Crypto,Channel}.swift`, Rust
`windows/src/{noise,handshake,net}.rs`, Python reference `tools/glide_noise.py`. All three are
hand-written from the Noise spec and checked against the official vectors (§4).

### 1.2 Wire sequence

```
viewer → host   ClientPreamble (24) ‖ u16 len ‖ msg1          -> e
host → viewer   HostPreamble (8)   [‖ u16 len ‖ msg2]         <- e, ee, s, es
viewer → host   u16 len ‖ msg3   [‖ ClientHello record]       -> s, se
                ---- transport records (§2) from here ----
host ↔ viewer   auth phase (§2.4): ServerHello, or AuthResult, or pairing
```

Handshake messages are framed as `u16 length ‖ message`, length ≤ **1024** (larger = protocol
error, close). The Noise **prologue** is the 24-byte ClientPreamble, so tampering with it breaks
the handshake.

**ClientPreamble** (24 bytes):

| off | size | field |
|----|----|----|
| 0 | 4 | magic `"GLD2"` |
| 4 | 2 | `u16` max version the viewer speaks (= 2) |
| 6 | 2 | `u16` min version it accepts (= 2) |
| 8 | 16 | reserved, zero |

The reserved bytes also make the viewer's first flight 58 bytes: a v1 host reads exactly 54 bytes,
sees the wrong magic and closes at once instead of waiting for its auth timeout.

**HostPreamble** (8 bytes): `"GLD2"`, `u16 version`, `u16 status`.

| status | meaning | then |
|----|----|----|
| 0 | OK, `version` is the negotiated version (2) | msg2 follows |
| 1 | no common version (`version` = host's highest) | host closes |
| 2 | host is paused (not accepting viewers) | host closes |
| 3 | rate limited: too many failed attempts from this address (§2.5) | host closes |

The host decides the status after reading ClientPreamble + msg1 and **before any DH**. Status ≠ 0
is unauthenticated; the viewer only uses it for its status text and retry timing.

**Version negotiation.** The host picks the highest version in `[min, max]` it supports (only 2
exists). The negotiated version is repeated inside msg2's encrypted payload; the viewer aborts if
it differs from the preamble's (downgrade of the plaintext preamble is detected).

### 1.3 Payloads

- **msg1** payload: empty (it is unencrypted). A nonempty payload is a protocol error.
- **msg2** payload (encrypted to the viewer's ephemeral, from the host):

  | size | field |
  |----|----|
  | 2 | `u16 version` (= HostPreamble version) |
  | 1 | `u8 flags`: bit0 = the host's pairing window is open |
  | 32 | pairing commitment `C = SHA-256("glide-v2 pair commit" ‖ n_h)` |

  `n_h` is 32 random bytes the host draws per connection. msg2 also reveals the host's static key
  to whoever initiates (XX): it is not secret.
- **msg3** payload (encrypted, from the viewer):

  | size | field |
  |----|----|
  | 1 | `u8 flags`: bit0 = **pair request** (§2.4) |
  | 32 | `n_v`: 32 random bytes |
  | str | viewer name (≤ 255 bytes; truncated on a character boundary) — shown in the Mac's list |

The viewer checks the host's static key from msg2 against its pin **before** writing msg3; on a
mismatch it closes without sending msg3 (an impostor learns nothing about the viewer's identity).

### 1.4 Keys and hash

After msg3 both sides run Noise `Split()`: the first key encrypts viewer→host (`c2s`), the second
host→viewer (`s2c`). `h` = Noise `GetHandshakeHash()` (32 bytes) after msg3. Rekeying is not used.

Low-order public keys (all-zero DH output) are rejected by all implementations.

## 2. Record layer and authentication

### 2.1 Records

After the handshake every message travels as a record:

| size | field |
|----|----|
| 4 | `u32` ciphertext length `L` (includes 16-byte tag), `17 <= L <= 32 MiB` |
| L | ChaCha20-Poly1305 ciphertext + tag |

- Key: `c2s` for client→host, `s2c` for host→client (from §1.4).
- Nonce (12 bytes): `00 00 00 00` ‖ `u64` little-endian record counter. Each direction has its own
  counter starting at **0**, incremented per record. AAD: empty. This is exactly a Noise transport
  `CipherState` (`EncryptWithAd("", …)`); Glide frames it with its own `u32` length and does not
  apply Noise's 65535-byte message limit.
- Plaintext: `u8 message_type` ‖ payload.

Any decrypt failure is fatal: close the connection.

### 2.2 Auth-phase messages

Message types `0x08–0x0F` are reserved for the auth phase; they are only valid before
`ServerHello`.

| dir | type | name | payload |
|----|----|----|----|
| H→C | `0x08` | AuthResult | `u8 code` (below) |
| H→C | `0x09` | PairReveal | 32 bytes `n_h` |
| C→H | `0x0A` | PairConfirm | `u8 match` (1 = the user confirmed the codes match, 0 = declined) |

AuthResult codes — the host closes the connection after any nonzero code:

| code | meaning | viewer shows |
|----|----|----|
| 0 | paired: both users confirmed; the viewer pins the host key and sends ClientHello | — |
| 1 | unknown viewer: key not paired, no pair request | "doesn't recognize this PC — Pair New Viewer…" |
| 2 | pair request, but the host's pairing window is closed | "Not paired yet — Pair New Viewer…" |
| 3 | pairing declined (on the Mac, or a typed code didn't match) | "declined on the Mac" |
| 4 | pairing timed out (nobody confirmed on the Mac within 60 s) | "timed out" |
| 5 | busy: another pairing is in progress | "busy, try again" |

Reference bytes: `AuthResult{1}` = `08 01`, `PairConfirm{1}` = `0a 01`, `PairReveal` = `09` ‖ 32 bytes.

### 2.3 Identities and pinning

- **Host identity:** X25519 key in `~/Library/Application Support/Glide/host-key` (64 hex chars,
  mode 0600, folder 0700), created on first start. It is a file rather than a Keychain item: the
  host is a LaunchAgent on a usually headless Mac; a legacy-keychain item is bound to the code
  signature, so a rebuilt binary or the CLI could raise an "allow access" prompt nobody can click,
  and the data-protection keychain needs a provisioning-profile entitlement. Same-user code can
  read the file — but it could also replace the app. An unreadable/corrupt key file is fatal
  (never silently regenerated: that would look like an impersonation to every viewer).
- **Host pin list:** `host.json` `"pairedViewers": [{"name", "key" (hex), "paired" (ISO 8601)}]`.
  Menu: *Paired Viewers ▸ name ▸ Remove…*; CLI `glide-host --paired`, `--unpair NAME|KEY`.
  Removing a viewer ends its session.
- **Viewer identity:** `identity.dpapi` next to `config.json` (DPAPI `CryptProtectData`, current
  user, extra entropy). Created on first use; an undecryptable file is an error, not replaced.
- **Viewer pins:** `config.json` `"pinned_hosts": {target: {"key", "name", "paired"}}` where
  `target` is `host:port` (lowercase, default port added) when the viewer knows the host's address
  (for connections in both directions), or `listen:PORT` in listen-only mode; with an address and
  no pin under it, a `listen:PORT` pin is used and copied to the address. Tray *Forget host
  (unpair)…* or `--forget-host` removes it.

Rules:

1. Viewer, after msg2: if a key is pinned for the target and differs → abort before msg3
   ("HOST KEY CHANGED"). Unpinned → msg3 with the pair request bit, but only if msg2 says the
   host's pairing window is open; otherwise the viewer closes without msg3 and says to open
   *Pair New Viewer* on the Mac. A viewer that did not dial (the host connected to it) accepts a
   pairing only during its **inbound pairing window**: 15 minutes from start, from opening or
   closing its setup dialog, from *Forget host*, or from the tray's *Allow the Mac to pair*; one
   successful pairing closes it. Outside it, an unpinned inbound connection is closed after msg2
   with no prompt.
2. Viewer pair request bit = no pin for this target, **or** the host answered AuthResult 1 earlier
   in this process (it forgot us): then pairing runs again, still requiring the pinned host key.
3. Host, after msg3: pair request → pairing (§2.4) if the window is open (else 2, or 5 if busy).
   No pair request → paired key: continue (`ClientHello` → `ServerHello`); unknown key: AuthResult 1.
4. Paired viewers pipeline `ClientHello` right after msg3. `ServerHello` (as before) means
   accepted; there is no AuthResult 0 on this path.

### 2.4 Pairing

The host's **pairing window** opens for **2 minutes** from the menu (*Pair New Viewer…*) or
`glide-host --pair`; one successful pairing closes it; only one pairing runs at a time.

```
viewer                                   host
msg3 (pair request, n_v)  ─────────────►
                          ◄───────────── PairReveal (n_h)
check SHA-256("glide-v2 pair commit" ‖ n_h) == C from msg2, else abort
both show SAS = code(h, n_v, n_h); each user confirms on their own screen
PairConfirm (1/0)         ─────────────►
                          ◄───────────── AuthResult 0 (after both said yes; host pins the viewer)
pin the host key; ClientHello ─────────► ServerHello …
```

**SAS:** `d = SHA-256("glide-v2 sas" ‖ h ‖ n_v ‖ n_h)`;
`code = (d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3]) mod 1 000 000`, shown as two groups of three
digits, `"%03u %03u"` (e.g. `973 429`).

Why the commitment and nonces: with a 20-bit code, a man in the middle running one handshake with
each side could otherwise grind its own ephemeral keys/payloads until both codes match. Here the
host commits to `n_h` in msg2 before it sees anything the viewer contributes in msg3, the viewer's
fresh `n_v` arrives only after the host side's msg2 is fixed, and `n_h` is revealed only after
msg3. Whichever side the attacker completes last, the code it ends up with is uniformly random to
it: each attempt succeeds with probability 10⁻⁶ and each failed attempt shows two different codes
to the users. (Same structure as ZRTP's hash commitment / Bluetooth numeric comparison.)

**Confirmation.** The viewer shows a dialog with the code and both key fingerprints
(fingerprint = first 8 bytes of SHA-256(public key) in hex, `aaaa bbbb cccc dddd`) and buttons
*Codes Match — Pair* / *Cancel*. On both sides **Cancel is the default** (Return/Escape), the
confirm button is enabled only 1 s after the prompt appears, and the prompt does not take keyboard
focus from another app (the viewer flashes its taskbar button; the Mac alert floats on top). The
viewer's prompt names the address the connection actually came from. The Mac confirms either in a
menu-bar alert (same buttons) or by
**typing** the code the PC shows (`glide-host --pair` in a terminal, or `glide-host --pair-code
NNNNNN`); a typed code is compared by the host, so a mismatch declines (AuthResult 3).

**Timeouts (pre-auth resources).**
- Until the viewer has received a PairReveal of at most 49 bytes (record body) whose nonce opens
  the msg2 commitment, the normal pre-auth deadline applies (5 s wall clock when dialing; the
  listen-mode pre-auth deadline), counted as a total, not per read. Only then is the user
  prompted; the prompt plus the host's verdict get a total of **120 s**, after which the viewer
  closes the prompt and the connection. AuthResult after the prompt must be ≤ 18 bytes (body).
- The host enters the pairing state only after an authenticated msg3 with the pair request bit
  **and** an open window; it waits at most **60 s** for both confirmations (then AuthResult 4).
  Records from an unauthenticated (not yet streaming) peer are capped at 64 KiB.
- Cancelling the window on the Mac declines a pairing in progress.

### 2.5 Rate limiting

The host counts failed attempts per IPv4 address / IPv6 /64 (IPv4-mapped IPv6 as IPv4):
handshake errors, timeouts, AuthResult 1–5, a viewer hanging up after msg2. The address is then
refused with HostPreamble status 3 for 1 s, doubling to 60 s; a successful session clears it,
and opening the pairing window clears all of it (the viewer being paired may have been refused a
moment ago). When the host dials out, its redial interval backs off the same way (2 s → 60 s)
while the viewer keeps refusing it, and opening the pairing window redials immediately.
Sessions the host dialed are never charged to the inbound limiter (its own failed dials must not
refuse the viewer when it dials in).

The viewer keeps its own per-address backoff and IP allowlist (`allowed_peers`, TOFU-pinned IP;
`windows/src/peers.rs`) in front of the handshake for connections it accepts. Answers that prove
a real host (AuthResult 1, 2 and 5), the viewer declining to pair because the host's window is
closed, and a connection closed before the host sent a byte (left over in the accept queue) are
not counted; handshake errors, timeouts, key mismatches and AuthResult 3/4 are. If `allowed_peers`
holds only the TOFU-pinned IP and a host key is pinned, a connection from a new address (the Mac
got a new DHCP lease) is still admitted, under a stricter backoff, and must present the pinned
key before msg3; after an authenticated session the pin moves to the new address. A CIDR entry or
several entries keep the strict allowlist. Refusals show in the viewer's status line.

Rejections are logged (before authentication through a per-address limiter: routine connection
lines and security events such as unknown viewers or pair requests have separate budgets, with a
summary of what was suppressed); the host's menu shows the last one ("Rejected unknown viewer “X” (ip)",
with a repeat count). No dialog appears for them.

### 2.6 Version detection

- **v1 viewer → v2 host:** the host sees `"GLD1"`, reads the rest of the 54-byte v1
  ClientHandshake and replies 70 bytes `"GLD1"`, `u16 2`, 64 zero bytes; the v1 viewer reports
  "unsupported protocol version 2". The host logs it and notes "Rejected a Glide v1 viewer".
- **v2 viewer → v1 host:** the v1 host reads 54 bytes, rejects the magic and closes without
  answering; the viewer reports that the host closed before answering and is probably still v1.

### 2.7 Legacy: v1 password handshake (removed)

v1 (`"GLD1"`, version 1) sent a 54-byte ClientHandshake (X25519 ephemeral + nonce) and a 70-byte
HostHandshake (+ a per-host salt), and derived `c2s`/`s2c` with
`HKDF-SHA256(ikm = X25519 ‖ PBKDF2-HMAC-SHA256(password, salt, 100000, 32), salt = SHA-256(transcript),
info = "glide v1 session keys", L = 64)`. Its flaw: an active impostor of either side obtained a
value (the peer's first record) to test password guesses against offline. It is no longer
implemented; v2 hosts leave `salt`/`password` in host.json and v2 viewers leave `password.dpapi`
in place (unused) so a rollback to v1 binaries still works.

## 3. Messages

### Client → Host

| type | name | payload |
|----|----|----|
| `0x0A` | PairConfirm | auth phase only, see §2.2 |
| `0x01` | ClientHello | `u16 version` (= 2), `u32 codec_caps`, `u16 view_w`, `u16 view_h` (physical pixels of the monitor the viewer window is on — not necessarily the primary), `u8 mode`, `u8 max_fps`, `str client_name` |
| `0x10` | MouseMove | `f32 x`, `f32 y` — normalized 0..1 over the host display |
| `0x11` | MouseButton | `u8 button` (0 L, 1 R, 2 M, 3 back, 4 fwd), `u8 down` (1/0) |
| `0x12` | MouseWheel | `f32 dx`, `f32 dy` — in wheel notches (1.0 = one notch, fractional OK). `dy > 0` = wheel pushed away from user (scroll up). `dx > 0` = scroll right |
| `0x13` | Key | `u16 hid_usage` (USB HID Keyboard page 0x07), `u8 down` (1/0). A down for an already-held key is an autorepeat |
| `0x14` | ReleaseAll | (none) — host releases every held key/button |
| `0x15` | ViewSize | `u16 view_w`, `u16 view_h` — physical pixels of the monitor/area the viewer will present on (the window's current monitor in fullscreen). Sent whenever it changes (window moved to another monitor, display mode change). The host re-captures so the encoded width ≤ `view_w` and follows with `VideoConfig` + keyframe |
| `0x16` | SetDisplayPreference | `u8 mode` — Mac display-mode preference for this session, see §3.3 |
| `0x17` | Scroll | `u8 flags`, `f32 dx`, `f32 dy` — wheel/touchpad scroll with its source, see §3.6 (only after `InputCaps` bit0) |
| `0x18` | MouseDelta | `i16 dx`, `i16 dy` — relative pointer motion, see §3.6 (only after `InputCaps` bit1) |
| `0x19` | KeyExtra | `u8 kind`, then a kind-specific body: lock-key state or a consumer (media) key, see §3.6 (only after `InputCaps` bit2/bit3) |
| `0x1A` | SelectDisplay | `u32 display_id` — which Mac display to stream (0 = the host's default), see §3.5 |
| `0x20` | RequestKeyframe | (none) |
| `0x21` | SetMode | `u8 mode` (0 fast, 1 sharp), `u32 bitrate_kbps` (0 = auto), `u8 max_fps` (0 = keep) |
| `0x30` | Ping | `u64 client_time_us` |
| `0x50` | Clipboard | clipboard snapshot, see §5 (only after the host sent `ClipboardCaps`) |
| `0x62` | AudioEnable | `u8 enabled` — see §3.2 |
| `0x70`–`0x79` | File transfer | see §6 (only after the host sent `FileCaps`) |
| `0x80` | LatencyEnable | `u8 flags` — see §3.4 |
| `0x82` | LatencyReport | viewer latency breakdown — see §3.4 |

`codec_caps` bits (despite the name, a general capability mask): bits 0–7 are video codecs —
`0` HEVC 4:2:0, `1` HEVC 4:4:4, `2` H.264 4:2:0; bits 8+ are non-video features — `8` clipboard
sync (§5), `9` audio PCM, `10` audio Opus (reserved) (§3.2), `11` file transfer (§6), `12` input
extensions (§3.6), `13` display selection (§3.5). Hosts ignore bits they don't know;
codec selection looks at bits 0–7 only.
`mode`: `0` fast (4:2:0 only), `1` sharp (4:4:4 every frame), `2` **hybrid** (4:2:0 while the screen
changes + a 4:4:4 refinement layer once it settles; see §3.1). Hybrid requires `codec_caps` bit 1;
the host falls back to fast otherwise. Viewers that support it should default to hybrid.

Modifier remapping (e.g. Windows Ctrl → Mac Command) is the **client's** job:
the host injects exactly the HID usages it receives.

`MouseMove` coordinates span the edges of the captured display, not the centers of its edge
pixels: `x = 0` is the left edge and `x = 1` the right edge, so the host maps `x · width` (in its
own units, e.g. points), clamped inside the display. Viewers send the center of the pixel under
the pointer within the drawn video rectangle, `(px + 0.5) / rect_width` (likewise for `y`),
clamped to 0..1 when the pointer is over a letterbox bar.

Input values are untrusted: a `MouseMove` or `MouseWheel` with a NaN or infinite `f32`, a
`MouseMove` coordinate outside ±1000 or a `MouseWheel` delta outside ±10000 notches is malformed,
and the host drops the message (it logs it; the session continues). Finite coordinates outside
0..1 are clamped to the display.

### Host → Client

| type | name | payload |
|----|----|----|
| `0x08` | AuthResult | auth phase only, see §2.2 |
| `0x09` | PairReveal | auth phase only, see §2.2 |
| `0x02` | ServerHello | `u16 version` (= 2), `str host_name`, then a `VideoConfig` body (below) |
| `0x04` | SharpLayerConfig | `VideoConfig` body for the refinement layer (hybrid mode only; sent right after `ServerHello`/`VideoConfig`). Same width/height as the base layer, HEVC 4:4:4 |
| `0x05` | DisplayInfo | `u8 preference`, `u16 mode_w`, `u16 mode_h`, `u8 hidpi` — see §3.3 |
| `0x06` | DisplayList | the Mac's displays and which one is streamed — see §3.5 (only to clients with caps bit 13) |
| `0x07` | DisplayChanged | `u32 display_id`, `u8 reason`, `u32 requested_id` — see §3.5 (only to clients with caps bit 13) |
| `0x03` | VideoConfig | `u16 width`, `u16 height` (encoded pixels), `u8 codec` (1 HEVC, 2 H.264), `u8 chroma` (0 4:2:0, 1 4:4:4), `u8 color` (0 BT.709 limited), `f32 scale` (host backing scale, e.g. 2.0) |
| `0x31` | Pong | `u64 client_time_us` (echoed), `u64 host_time_us` |
| `0x40` | VideoFrame | `u32 frame_id`, `u64 capture_time_us` (host monotonic), `u8 flags`, [rects], then Annex-B elementary stream bytes. Flags: bit0 keyframe; bit1 refresh (re-encode of unchanged content for quality — `capture_time_us` is the original capture, so exclude from latency stats); bit2 **sharp layer** (decode with the refinement-layer decoder, see §3.1); bit3 **has rects**: the payload starts with `u16 n` then `n` × (`u16 x, y, w, h`) in encoded pixels, before the Annex-B bytes |
| `0x41` | CursorPos | `f32 x`, `f32 y` (normalized), `u8 visible` |
| `0x42` | CursorShape | `u32 shape_id`, `u16 w`, `u16 h`, `u16 hot_x`, `u16 hot_y`, then `w*h*4` bytes BGRA, straight (non-premultiplied) alpha, top-down rows |
| `0x43` | CursorShapeRef | `u32 shape_id` — switch to a previously sent shape |
| `0x44` | InputCaps | `u32 flags` — which §3.6 input messages the host accepts (only to clients with caps bit 12) |
| `0x45` | — | reserved for §3.6 |
| `0x50` | Clipboard | clipboard snapshot, see §5 (only to clients with caps bit 8) |
| `0x51` | ClipboardCaps | `u32 formats`, `u32 max_bytes` — see §5 (only to clients with caps bit 8) |
| `0x60` | AudioConfig | see §3.2 (only to clients with caps bit 9) |
| `0x61` | AudioFrame | see §3.2 (only to clients with caps bit 9) |
| `0x70`–`0x79` | File transfer | see §6 (only to clients with caps bit 11) |
| `0x81` | FrameTiming | per-frame host timestamps, see §3.4 (only after `LatencyEnable`) |

Rules:
- Host sends `ServerHello` after it accepted the viewer (§2.3) and received `ClientHello`.
- A `VideoConfig` (or `ServerHello`) always precedes the first `VideoFrame` of a new
  configuration, and the next `VideoFrame` is a keyframe. Client must reset its decoder.
- Keyframes carry VPS/SPS/PPS (HEVC) or SPS/PPS (H.264) in-band, Annex-B with 4-byte start codes.
- No B-frames; decode order == display order. Client should display every frame immediately.
- The host only sends frames when the screen changes; long gaps are normal.
- `CursorShape` sizes are in **host pixels**; client may scale by its own view scale. `w` and `h`
  are at most 256 (hosts don't send larger shapes; viewers ignore them). Viewers bound their shape
  cache (Glide's: 1024 shapes / 64 MiB, then it starts over); a `CursorShapeRef` to a shape the
  viewer doesn't have leaves the current cursor unchanged.

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

## 3.3 Mac display preference (v1.3)

The host may switch the Mac's display mode to suit the viewer (`automatic` policy, configurable on
the Mac). The viewer can choose the preference **for the current session**:

| dir | type | name | payload |
|----|----|----|----|
| C→H | `0x16` | SetDisplayPreference | `u8 mode` |
| H→C | `0x05` | DisplayInfo | `u8 preference`, `u16 mode_w`, `u16 mode_h`, `u8 hidpi` |

`mode` / `preference`: `0` automatic, `1` crisp (non-HiDPI, pixels 1:1 with the viewer), `2` smooth
(HiDPI looking like ~2/3 of the viewer), `3` retina (HiDPI, backing pixels 1:1 with the viewer),
`4` manual ("don't change").

- `SetDisplayPreference` applies immediately (the host may switch modes, then re-captures:
  `VideoConfig` + keyframe as usual). It lasts until the session ends; it is not persisted, and a
  change of the policy on the Mac itself overrides it. Unknown values are ignored.
- `DisplayInfo` reports the preference in force for this session and the current mode: `mode_w` ×
  `mode_h` is the "looks like" size in points, `hidpi` = 1 if the mode has Retina backing (pixels =
  2× points). `0×0` = unknown. The host sends it right after `ServerHello` (and the clipboard/audio
  messages that follow it) and again whenever the preference or mode changes.
- Older peers ignore these: viewers ignore unknown host message types; a host that doesn't know
  `0x16` logs and drops it. A viewer that never got `DisplayInfo` should treat the feature as unavailable.

Reference encodings (both implementations test these):

```
SetDisplayPreference {3 retina}                     16 03
DisplayInfo {automatic, 1920x1080, hidpi}           05 00 8007 3804 01
DisplayInfo {manual, 2560x1600, not hidpi}          05 04 000a 4006 00
```

## 3.4 Latency instrumentation (v1.4)

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
  implements §3.4). The host only logs/displays it.

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

## 3.5 Multiple displays (v1.6)

A Mac can have several displays (built-in panel, external monitors, virtual displays). The host
streams exactly one of them; the viewer can see the list and pick which one. Message types
`0x06–0x07` (H→C) and `0x1A–0x1C` (C→H) are reserved for this; `0x1B–0x1C` are unused.

**Capability.** ClientHello `codec_caps` bit **13** = `DISPLAYS`. A host sends `0x06`/`0x07` only
to viewers that set it, so an old viewer never sees them; an old host ignores the bit and logs and
drops `0x1A`. A viewer sends `SelectDisplay` only after it received a `DisplayList`.

| dir | type | name | payload |
|----|----|----|----|
| H→C | `0x06` | DisplayList | `u32 streamed_id`, `u32 selected_id`, `u8 count`, then `count` × display (below) |
| H→C | `0x07` | DisplayChanged | `u32 display_id`, `u8 reason`, `u32 requested_id` |
| C→H | `0x1A` | SelectDisplay | `u32 display_id` |

Display entry (35 bytes + name):

| size | field |
|----|----|
| 4 | `u32 id` — the macOS `CGDirectDisplayID`. **Volatile**: valid for this connection only |
| 1 | `u8 flags` — bit0 main display, bit1 built-in panel, bit2 HiDPI (current mode has Retina backing), bit3 default (what `SelectDisplay(0)` streams); other bits zero |
| 4 + 4 | `i32 x`, `i32 y` — top-left corner in global points (the main display's top-left is 0,0; y grows downwards) |
| 2 + 2 | `u16 width`, `u16 height` — current mode, points ("looks like") |
| 2 + 2 | `u16 pixel_width`, `u16 pixel_height` — current mode, backing pixels |
| 2 | `u16 refresh` — refresh rate in 1/100 Hz (5994 = 59.94 Hz), 0 = unknown |
| 4 + 4 + 4 | `u32 vendor`, `u32 model`, `u32 serial` — EDID identity (`CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber`), 0 = unknown |
| 2 + n | `str name` — the display's localized name (`NSScreen.localizedName`), e.g. `Built-in Retina Display` |

`DisplayChanged.reason`:

| value | meaning |
|----|----|
| 0 | selected — the viewer's `SelectDisplay` was applied |
| 1 | unavailable — `requested_id` is not a display the host can stream; nothing changed |
| 2 | fallback — the selected display went away (unplugged, lid closed, asleep); streaming the default |
| 3 | restored — the selected display came back; streaming it again |
| 4 | host — someone on the Mac picked the display (menu bar) |
| 5 | default — no display is selected and the host's default changed (e.g. a new main display) |

Rules:
- **Default display.** Without a selection the host streams its default: its configured display
  (`glide-host --display ID`) while that is online, otherwise the current main display. It
  re-resolves on every capture start, never caching an ID.
- **List.** The host sends `DisplayList` once after `ServerHello`, before the first `VideoFrame`,
  and again whenever its content changes: a display appears or goes away, a mode/arrangement changes, or the
  streamed display changes. It lists the online, non-mirrored displays (at most 32) ordered by `x`,
  then `y`, then `id` (left to right), so "next display" is the one to the right. `streamed_id` is
  the display being captured; `selected_id` is the session's selection (0 = none, following the
  default; while the selected display is away it keeps the selection's last id, which is then
  not in the list). `streamed_id` may be missing from the list too (e.g. the only display is
  asleep); viewers must cope.
- **Selecting.** `SelectDisplay(id)` selects display `id` for the rest of the session (0 clears the
  selection). The host does not persist it. If `id` is not in its current list the host answers
  `DisplayChanged(streamed, 1, id)` and changes nothing. Otherwise it re-captures that display
  (`VideoConfig` + keyframe as usual), moves input mapping to it (`MouseMove` etc. are normalized
  over the streamed display), applies its display-mode policy (§3.3) to the new display and gives
  the previous display its pre-session mode back. Selecting the display already streamed answers
  `DisplayChanged(id, 0, id)` without re-capturing.
- **Order after a switch:** `VideoConfig` (+ `SharpLayerConfig`), `DisplayList`, `DisplayChanged`,
  then the keyframe of the new capture. A viewer can therefore name the new display from the list
  it just received. A `DisplayInfo` describing the new display's mode follows (it may arrive after
  the keyframe).
- **Hot-plug.** When the selected display goes away the host falls back to the default display
  and sends `DisplayChanged(default, 2, selected)`. It keeps the selection's identity (vendor,
  model, serial, name) for the rest of the session: when a display with that identity comes back
  (possibly under a new id) it switches back and sends `DisplayChanged(id, 3, id)`. Without a
  selection, a change of the default display is reported as reason 5.
- **Identity.** Display ids can change across reconnects, reboots and re-plugs. A viewer that wants
  to remember a choice stores the display's identity and, after the first `DisplayList` of a new
  connection, maps it back with the matching rule below; if it matches a display other than the
  streamed one it sends `SelectDisplay`. If nothing matches it leaves the default alone.

**Identity matching (normative; both sides use it, checked by the vectors).** Given a remembered
`(id, vendor, model, serial, name)` and the current list, the match is:

1. the entry with the same `id` **and** the same `vendor`, `model`, `serial`, if any; else
2. if the remembered `serial` ≠ 0: the first entry with the same `vendor`, `model` and `serial`;
   else none (a different unit of the same model is not the same display); else
3. (remembered `serial` = 0) the entries with the same `vendor` and `model` and `serial` = 0 —
   when `vendor` and `model` are both 0, only those whose `name` is also equal — preferring the
   first whose `name` is equal, else the first; else none.

"First" is in list order. Names are compared exactly (UTF-8 bytes).

Reference encodings (`docs/display-vectors.json`, generated by `tools/mock_host.py
--display-vectors`; checked by `glide-selftest`, `cargo test` and `mock_host.py --selftest`):

```
SelectDisplay {id 2}                    1a 02000000
SelectDisplay {automatic}               1a 00000000
DisplayChanged {id 2, fallback, req 5}  07 02000000 02 05000000
DisplayList {streamed 1, selected 0, [id 1 "Built-in Retina Display" main|builtin|hidpi|default,
             0,0 1512x982 pt 3024x1964 px 120 Hz, 0610/a04e/0]}
  06 01000000 00000000 01 01000000 0f 00000000 00000000 e805 d603 d00b ac07 e02e
     10060000 4ea00000 00000000 1700 4275696c742d696e20526574696e6120446973706c6179
```

## 3.6 Input extensions (v1.7)

Optional input messages for native-feeling control: scrolling that keeps its source (touchpad
or wheel), relative pointer motion for games and 3D apps, lock-key sync and media keys. They are
negotiated, so old peers on either side lose nothing:

- The viewer sets `codec_caps` bit **12** in `ClientHello` when it implements this section.
- A host that implements it answers such a viewer with **`InputCaps` (`0x44`)** once, after
  `ServerHello` (next to `ClipboardCaps` / `FileCaps`). It never sends `InputCaps` to a viewer
  without bit 12. `0x45` is reserved.
- The viewer sends `0x17`–`0x19` **only** for features whose `InputCaps` bit is set. Without
  `InputCaps` (an older host) it keeps using `MouseWheel` / `Key` as before. (An older host logs
  and drops an unknown message after authentication, but viewers must not rely on that.)

`InputCaps` flags (viewers ignore bits they don't know; hosts set only what they implement):

| bit | feature | message |
|----|----|----|
| 0 | scroll with source | `0x17` Scroll |
| 1 | relative pointer motion | `0x18` MouseDelta |
| 2 | lock-key state | `0x19` kind 0 |
| 3 | consumer (media) keys | `0x19` kind 1 |

### `0x17` Scroll (C→H)

`u8 flags`, `f32 dx`, `f32 dy`. The deltas have the units and signs of `MouseWheel` (`0x12`):
notches, 1.0 = one detent = Windows `WHEEL_DELTA` 120, `dy > 0` scrolls up, `dx > 0` scrolls
right. They describe the scroll the user wants: a viewer-side "natural scrolling" option is
applied by the viewer before sending. `flags` bit0 **precise**: the source is continuous (a
precision touchpad or a high-resolution wheel) rather than a notched wheel. Other bits are 0 and
ignored. A viewer that negotiated bit0 sends `Scroll` instead of `MouseWheel`.

The host should inject:
- **discrete** (bit0 = 0): a line-based mouse-wheel scroll, 3 lines per notch (the Windows
  default), so applications apply their own wheel behavior (for example smooth-scroll animation);
- **precise** (bit0 = 1): pixel scrolling (48 px per notch) as a gesture: the first event after
  a pause begins it, later events continue it, and the host ends it after about 100 ms without a
  precise event (or when a discrete scroll, `ReleaseAll` or a disconnect intervenes).

For `MouseWheel` from viewers without this section, hosts may infer the source: whole-notch deltas
are discrete, fractional ones precise.

### `0x18` MouseDelta (C→H)

`i16 dx`, `i16 dy`: relative motion in device counts, without pointer acceleration (Windows raw
input), `+x` right, `+y` down. The viewer sends it only while its relative ("pointer lock") mode
is on, which hides and confines its local cursor; larger motions are split over several messages.
The host moves its pointer by (`dx`, `dy`) points from where it is, clamped to the display, and
reports the unclamped motion as the event's delta, so applications that read deltas (games, 3D
viewports) keep turning at the screen edge. Buttons and scrolling keep using `0x11`/`0x12`/`0x17`.
A later `MouseMove` returns to absolute positioning.

### `0x19` KeyExtra (C→H)

`u8 kind`, then:

| kind | name | body |
|----|----|----|
| 0 | LockState | `u8 locks` — bit0 Caps Lock on, bit1 Num Lock on, bit2 Scroll Lock on |
| 1 | ConsumerKey | `u16 usage` (USB HID Consumer page `0x0C`), `u8 down` (1/0) |

Hosts ignore kinds they don't know.

- **LockState** is the viewer's absolute lock-key state. With bit2 negotiated the viewer leaves
  the Caps Lock and Num Lock keys to its own OS (so its LEDs and state stay right) instead of
  forwarding them as `Key`, and sends `LockState` after `InputCaps`, whenever it regains focus and
  whenever a lock key changes. The host applies Caps Lock to the key events it injects. A Mac has
  no Num Lock or Scroll Lock, so a Mac host ignores those bits (the viewer sends navigation usages
  for keypad keys while Num Lock is off).
- **ConsumerKey** carries media keys that have no Keyboard-page usage: `0xCD` Play/Pause, `0xB5`
  Next track, `0xB6` Previous track, `0xB7` Stop, `0xE2` Mute, `0xE9` Volume up, `0xEA` Volume
  down, `0x6F` Brightness up, `0x70` Brightness down. Hosts ignore other usages. (Keyboard-page
  Mute / Volume up / Volume down, `0x7F`–`0x81`, sent as `Key` by any viewer, are the same keys.)

Reference encodings (`docs/input-vectors.json`, generated by `tools/mock_host.py --input-vectors`;
`glide-selftest`, `cargo test` and `mock_host.py --selftest` check them):

```
InputCaps {0x0f}                          44 0f000000
Scroll {precise, dx 0, dy 0.25}           17 01 00000000 0000803e
Scroll {discrete, dx -1, dy 0}            17 00 000080bf 00000000
MouseDelta {dx 5, dy -3}                  18 0500 fdff
KeyExtra LockState {caps}                 19 00 01
KeyExtra ConsumerKey {0xcd play, down}    19 01 cd00 01
```

## 4. Test vectors

- `docs/noise-vectors.json`: the official Noise_XX_25519_ChaChaPoly_SHA256 vectors (cacophony,
  noise-c, snow; copied verbatim). Swift (`glide-selftest`), Rust (`cargo test`) and Python
  (`tools/glide_noise.py`) run all of them in both roles.
- `docs/test-vectors.json`: Glide v2 transcripts — a pairing session and a pinned session — from
  fixed static/ephemeral keys and nonces: preambles, msg1–3 and payloads, `h`, transport keys,
  commitment, SAS, every record and the exact bytes each side writes. Generated by
  `tools/gen_vectors.py` (Python reference); CI regenerates and compares it.
- `docs/test-vectors-rust.json`: the same schema with other inputs, generated by the Rust
  implementation (`GLIDE_REGEN_VECTORS=1 cargo test rust_transcript`).
- `docs/display-vectors.json`: §3.5 message encodings and identity-matching cases, generated by
  `tools/mock_host.py --display-vectors`; CI regenerates and compares it.
- `docs/file-transfer-vectors.json` (§6) and `docs/input-vectors.json` (§3.6): message encodings
  (and, for files, name-sanitizer cases) generated by `tools/mock_host.py --file-vectors` /
  `--input-vectors`; CI regenerates the input vectors and runs `mock_host.py --selftest`.

Swift replays both transcripts as host and as viewer byte for byte; Rust replays the Python one;
`tools/gen_vectors.py --check docs/test-vectors-rust.json` replays the Rust one in Python.

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


## 6. File transfer (v1.5)

Message types `0x70–0x7F` are reserved for file transfer: files and folders in both directions,
over the existing encrypted record layer, only inside an authenticated session.

### 6.1 Negotiation

1. The viewer sets `codec_caps` bit **11** (`FILES`) if it supports file transfer.
2. If (and only if) bit 11 is set and file transfer is enabled on the host, the host sends
   `FileCaps` right after `ServerHello` (after `ClipboardCaps`, if any). The host never sends
   `0x70–0x7F` to a viewer without bit 11.
3. The viewer sends file messages only after it received `FileCaps`, offers files only if `flags`
   bit 0 is set, and sends `FilePull` only if bit 1 is set.

### 6.2 Messages

"S" is the side sending the files, "R" the side receiving them; either peer can be either.

| type | name | dir | payload |
|----|----|----|----|
| `0x70` | FileCaps | H→C | `u32 flags` (bit0 the host accepts files, bit1 the host can send files), `u64 max_total_bytes`, `u32 max_files` (the host's limits for what it accepts) |
| `0x71` | FileOffer | S→R | `u32 transfer_id`, `u64 total_bytes`, `u32 count`, then `count` × (`str path`, `u64 size`, `i64 mtime_ms`) |
| `0x72` | FileAnswer | R→S | `u32 transfer_id`, `u8 status` (0 = accept, else a decline reason, §6.5), `str detail` |
| `0x73` | FileChunk | S→R | `u32 transfer_id`, `u32 file_index`, `u64 offset`, then 1..262144 bytes of file data (the rest of the message) |
| `0x74` | FileEnd | S→R | `u32 transfer_id`, `u32 file_index`, 32 bytes SHA-256 of the file's content |
| `0x75` | FileAck | R→S | `u32 transfer_id`, `u64 bytes` — chunk bytes of this transfer received and written so far |
| `0x76` | FileCancel | either | `u32 transfer_id`, `u8 reason` (§6.5), `str detail` |
| `0x77` | FileDone | R→S | `u32 transfer_id`, `u32 files` — every file was verified and saved |
| `0x78` | FilePull | C→H | (none) — "send me the files on your pasteboard" (Finder copy; viewer Ctrl+Alt+Shift+V) |
| `0x79` | FilePullResult | H→C | `u8 status` (0 = an offer follows, else a reason, e.g. 11 nothing to send), `str detail` |

- `path` is the file's path relative to the transfer, `/`-separated UTF-8 (a dropped folder
  `Photos` yields `Photos/a.jpg`, `Photos/2024/b.jpg`). Only regular files are listed: folders are
  implied by the paths (empty folders are not transferred). Invalid UTF-8 in any `str` of these
  messages is replaced (U+FFFD), never fatal.
- `mtime_ms`: modification time in ms since the Unix epoch (0 = unknown). The receiver applies it
  only if `1 ≤ mtime_ms ≤ 253402300799999` (year 9999); any other value is ignored, never an error.
- `total_bytes` must equal the sum of the sizes.
- **Transfer ids** are chosen by the sender: the viewer's are `1..=0x7FFFFFFF`, the host's have
  bit 31 set. A `FileCancel` therefore always identifies the transfer unambiguously. An offer whose
  id is outside the sender's range is refused (status 9).

### 6.3 Received names (normative)

Every path in an offer is untrusted. Receivers process it exactly like this (both
implementations are checked against `docs/file-transfer-vectors.json`, generated by
`tools/mock_host.py --file-vectors`):

1. **Refuse the offer** (status 3) if a path is empty, longer than 4096 bytes, starts with `/`
   or `\`, starts with a drive (`X:`, ASCII letter + colon), has more than 32 components, or
   has an empty (`a//b`, trailing `/`), `.` or `..` component. Also refuse an offer in which a
   path is both a file and a folder (case-insensitively), e.g. `x` and `x/y`.
2. **Sanitize each component**, in this order:
   1. replace with `_`: control characters U+0000–U+001F and U+007F; `\ : * ? " < > |`
      (`:` also blocks NTFS alternate data streams); invisible format characters U+061C,
      U+200B–U+200F, U+202A–U+202E, U+2060–U+2064, U+2066–U+2069, U+FEFF (bidi overrides
      that disguise extensions, zero-width characters);
   2. strip trailing `.` and ` ` (Windows drops them silently); if nothing is left, use `_`;
   3. if the part before the first `.`, without trailing spaces, is a Windows device name
      (case-insensitive ASCII: `CON PRN AUX NUL CONIN$ CONOUT$ COM0–COM9 LPT0–LPT9` and
      `COM¹²³ LPT¹²³`), prefix `_` (`con.txt` → `_con.txt`);
   4. if longer than 200 UTF-8 bytes, cut it to 200 bytes at a character boundary, keeping the
      extension (from the last `.`, if not at position 0 and at most 32 bytes); strip trailing
      `.`/` ` again. (200 leaves room for the collision suffix under the 255 limits of
      APFS/NTFS.)
   5. if step 4 cut the name, apply step 3 again: a cut can expose a device name
      (`CON` + 197 spaces + `xyz` → `CON` → `_CON`). A component is therefore at most 201 bytes.
3. **Never overwrite.** Files are saved under the receiver's download folder
   (host: `~/Downloads/Glide`, viewer: `<Downloads>\Glide`; configurable). Each top-level folder
   of the offer becomes a *new* folder — `Photos (2)`, `Photos (3)`… if the name is taken — so a
   transfer never writes into an existing folder (and never through an existing symlink). A file
   whose name is taken gets ` (2)` before its extension (`a.txt` → `a (2).txt`; dotfiles and
   folders get it at the end). The final rename is atomic and fails instead of replacing
   (`renamex_np(RENAME_EXCL)` / `MoveFileExW` without `REPLACE_EXISTING`).

### 6.4 Transfer flow

1. S sends `FileOffer` and waits for `FileAnswer`. R accepts or declines (limits, disabled,
   busy, bad names …). A sender runs one outgoing transfer at a time (it queues further requests
   locally); a receiver may decline a second concurrent offer with status 4.
2. After an accept, S sends the files in offer order. For each file: `FileChunk`s with
   contiguous offsets starting at 0 (each 1..262144 bytes, summing to the file's size), then
   `FileEnd` with the SHA-256 — also for empty files (no chunks).
3. R writes each file to a hidden temp file (`.glide-<id>-<index>.part`) in its final folder.
   On `FileEnd` it checks the size and SHA-256; only then it applies `mtime`, marks the file as
   downloaded (§6.6) and renames it into place (§6.3). A chunk for the wrong file, a gap, an
   overlap, data beyond the declared size, or a mismatch at `FileEnd` → R sends `FileCancel`
   (reason 9 or 8) and deletes the temp file. Files already completed stay.
4. **Flow control.** R sends `FileAck` after writing each chunk (and after each `FileEnd`). S keeps
   at most **1 MiB** of chunk data unacknowledged (`FILE_WINDOW`; Glide's senders use 512 KiB).
   A receiver may cancel (reason 9) if more than 4 MiB of chunks pile up unprocessed.
5. After the last file verifies, R sends `FileDone`. S reports success only on `FileDone`.
6. Either side may send `FileCancel` at any time (user cancel, read/write error, the source file
   changed while it was being read — reason 10). Both then drop the transfer; R deletes the
   partial file. Messages for an unknown or finished transfer id are ignored (not an error).
7. A disconnect ends all transfers; receivers delete partial files.

**Priority (normative intent: files never delay video or input).** Chunks are low-priority traffic:

- The host sends a chunk only while the connection's queued bytes (video backlog) are below
  256 KiB; otherwise it waits (re-checking when a chunk leaves the queue and every few ms).
- The viewer's sender is shared by input, control and chunks: a chunk is only written when no
  input/control message is waiting, so an input event never waits behind more than one chunk
  (≤ 256 KiB). Together with the ack window this bounds the file data ahead of any input event
  or video frame to ~512 KiB.

### 6.5 Status / reason codes

| code | meaning |
|----|----|
| 0 | ok / accepted (FilePullResult: an offer follows) |
| 1 | declined (receiving turned off) |
| 2 | too large (total size or file count over the receiver's limit) |
| 3 | unsafe file name (§6.3) |
| 4 | busy (another transfer in progress) |
| 5 | disk full |
| 6 | I/O error |
| 7 | cancelled by the user |
| 8 | verification failed (size or SHA-256 mismatch) |
| 9 | protocol error (bad id, order, offsets, flow control) |
| 10 | a source file changed while it was being sent |
| 11 | nothing to send (FilePull with no files on the pasteboard) |

### 6.6 Receiver safety

- Received files are **never opened or executed** automatically. Notifications only reveal them:
  Finder (`activateFileViewerSelecting`) on the Mac, Explorer `/select` on Windows.
- Files are marked as downloaded from the internet: macOS sets `com.apple.quarantine`
  (`0081;<hex time>;Glide;`) on every file and folder it creates, so Gatekeeper checks them on
  first open; Windows writes the Mark-of-the-Web stream `<file>:Zone.Identifier` with
  `[ZoneTransfer] ZoneId=3` (SmartScreen, Office Protected View). On file systems without
  streams (FAT/exFAT) the mark is skipped and logged.
- Senders refuse symlinks (and Windows junctions) and special files (FIFOs, devices, sockets)
  and never follow links inside folders; they skip `.DS_Store`. Both sides enforce size/count
  limits before sending/accepting (default 8 GiB, 10 000 files).

### Reference bytes

All in `docs/file-transfer-vectors.json` (checked by `glide-selftest`, `cargo test` and
`mock_host.py --selftest`), for example:

```
FileCaps   {flags 3, 8 GiB, 10000}            70 03000000 0000000002000000 10270000
FileChunk  {id 1, file 0, offset 0, "hello"}  73 01000000 00000000 0000000000000000 68656c6c6f
FileAck    {id 1, 5 bytes}                    75 01000000 0500000000000000
FileCancel {id 0x80000001, 7, "user"}         76 01000080 07 0400 75736572
FilePull                                      78
```
