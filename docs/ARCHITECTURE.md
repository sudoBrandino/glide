# Glide architecture

This document covers how frames and input move through the system, and why the pieces are
shaped the way they are. [`PROTOCOL.md`](PROTOCOL.md) is normative for anything on the wire —
message layouts, the handshake and the record layer — and this file doesn't repeat it.

```
capture ─► diff ─► encode ─► record layer ─► TCP ─► record layer ─► decode ─► canvas ─► present
 (SCK)   (TileDiff) (VT)    (ChaCha20-Poly1305)                     (MF/D3D11) (RGB10A2) (flip model)
```

## Components

| Side | Module | Role |
|---|---|---|
| Host | `mac/Sources/GlideCore` | Byte codec, message types, Noise XX handshake (`Noise.swift`, `Crypto.swift`), records (`Channel.swift`), pairing logic and rate limiter (`Pairing.swift`), control socket, HID keymap. It is shared by `glide-host`, `glide-probe` and `glide-selftest`. |
| Host | `glide-host/Trust.swift`, `TrustCLI.swift` | Host key file, paired-viewer list, pairing window + code confirmation (menu-bar alert, `glide-host --pair` over the control socket). |
| Host | `glide-host/main.swift` | CLI and `host.json` config, permission checks, the listener or dialer, power assertions. |
| Host | `glide-host/Session.swift` | One viewer connection: authentication, message dispatch, starting capture with retries, re-capture on display-mode changes and `ViewSize`, stats. |
| Host | `glide-host/VideoPipeline.swift` | ScreenCaptureKit streams, frame scheduling, change tracking, the hybrid sharp layer. |
| Host | `glide-host/TileDiff.swift` | Pixel diff between consecutive NV12 captures, which produces the dirty rects. |
| Host | `glide-host/Encoder.swift` | VideoToolbox compression sessions (HEVC 4:2:0 or 4:4:4, H.264). |
| Host | `glide-host/CursorMonitor.swift`, `InputInjector.swift` | Cursor shape and position out, CGEvent injection in. |
| Host | `glide-host/Power.swift` | Sleep and display-sleep assertions, display wake on input. |
| Host | `glide-host/ActiveDisplay.swift`, `GlideCore/Displays.swift` | Which display is served (PROTOCOL.md §3.5): the session's selection by identity, else Glide's virtual display while it is online ("Automatic"), else the `--display` pin, else the main display; the display list (a monitor that mirrors the virtual display is not listed). A `--display` pin turns the virtual display's default off. Capture, input, display-mode policy and the menu resolve it on use. |
| Host | `GlideCore/VirtualDisplayPolicy.swift`, `glide-host/VirtualDisplay.swift`, `CGlideVirtualDisplay` | The virtual display Glide streams by default, sized to the viewer's pixels and refresh rate. The pure, unit-tested parts are the mode plan, the 6K creation limits, the lifecycle (create, resume, standby, destroy), the arrangement (the monitor mirrors it, extend, or alone) and the read-back parser. The rest is the CGVirtualDisplay lifecycle: removal deferred while every display sleeps, mode read-back through `CGDisplayBounds` plus a child process, and mirror transactions that restore the monitor's mode. A runtime-lookup Objective-C shim wraps the private classes ([VIRTUAL_DISPLAY.md](VIRTUAL_DISPLAY.md)). |
| Host | `GlideCore/FileNames.swift`, `FileTransfer.swift` | File transfer (PROTOCOL.md §6): name sanitizer, receiver, sender, `FileTransferEngine`. |
| Host | `glide-host/HostFiles.swift` | Per-session file transfer wiring (chunk pacing on `bytesInFlight`, Finder pasteboard pull), notifications. |
| Viewer | `windows/src/{protocol,crypto,net}.rs` | Codec, crypto and TCP transport. These are platform independent and unit-tested on Linux, macOS and Windows. |
| Viewer | `windows/src/{hid,annexb,bench}.rs` | Scancode → HID table, Annex-B splitter, the headless benchmark. |
| Viewer | `windows/src/files.rs`, `win/files.rs` | File transfer: platform-independent service + Win32 drag & drop / notifications. |
| Viewer | `windows/src/displays.rs` | Mac display picker logic (§3.5): identity matching, cycling, remembered display, toasts. |
| Viewer | `windows/src/win/*` | Windows only: D3D11 device, Media Foundation decoders, renderer, window and input, cursor, `--probe`. |

## Host video pipeline

### Capture

- **Base stream.** `VideoPipeline` opens a ScreenCaptureKit stream of the chosen display:
  - It is scaled to the encoded size. That size is the display's native pixel width, capped at
    `--max-width` (default 3840) and at the viewer's reported width, and rounded down to even.
  - It runs at the target fps, with `showsCursor = false` because the cursor is sent separately.
  - It delivers `420v` (NV12, BT.709) frames, or BGRA in sharp mode.
- **Second stream (hybrid mode only).** A BGRA stream of the same display, which feeds the 4:4:4
  sharp layer.

Capture runs on a single serial `glide.video` queue, at user-interactive QoS. Each SCK callback
does the following:

1. It stores the buffer as `latest`: latest-frame-wins, and older captures are dropped.
2. It collects SCK's dirty rects for the update.
3. In hybrid mode it starts a pixel diff against the previous base capture (see below).
4. It calls `pump()`, which starts an encode when the encoder is free and the network isn't
   backed up.

### Scheduling and backpressure

- **Frames in flight:** the host keeps at most one frame in flight in the encoder (`GLIDE_INFLIGHT`
  overrides this). Two frames in flight measured +10–20 ms of pure queueing.
- **Network:** `canSend` checks the bytes still queued on the connection (6 MiB budget). When the
  socket backs up, new captures are skipped instead of queued, so latency stays bounded and the
  next frame sent is the newest one.
- **Idle frames:** the host sends nothing while the screen is idle. In fast mode, an idle timer
  re-encodes the last frame a few times as **refresh** frames (flag bit1), so the rate controller
  can spend spare bits sharpening static text. Viewers exclude these frames from latency stats.

### Diff: from SCK dirty rects to patch rects

SCK's dirty rects are coarse. Electron and Chromium apps report the whole window as dirty for a
one-line change. In hybrid mode, `TileDiff` compares the new NV12 capture with the previous one:

- It compares both the Y and CbCr planes.
- It works in 64×32 tiles and only looks inside SCK's dirty regions.
- It returns merged rects of tiles that actually changed.

The diff takes a few ms at 4K. It runs *while* the hardware encoder works on the same frame, and
its rects are attached when the encoded frame is sent.

Before sending, the rects go through `VideoPipeline.takeRects`:

- They are padded for codec bleed, aligned to 16 encoded pixels so that 4:2:0 chroma never
  straddles a rect edge, merged and clamped.
- If the rects cover enough of the frame that a full update is cheaper, the frame goes out without
  rects.
- A frame with an empty rect list means "decode, but the canvas is unchanged".

### Encode

`Encoder.swift` wraps VideoToolbox compression sessions:

- **Base layer:** HEVC 4:2:0 with low-latency rate control by default, no B-frames, and parameter
  sets in-band with every keyframe. H.264 is used when the viewer lacks HEVC. In sharp mode the base
  layer is HEVC 4:4:4.
- **Bitrate:** automatic by default, about 0.2 bits per pixel per frame (0.25 for 4:4:4), capped
  at 250 Mbps. `--bitrate-kbps` and `SetMode` override it.
- **Sharp layer:** a separate HEVC 4:4:4 session. It encodes only standalone IDRs, so it is
  configured at 5 fps with a generous per-frame bitrate budget, so that a still screen is crisp.

Typical timings on an M3 Pro:

- Base-layer encode: about 10–12 ms at 2560×1440 and about 18 ms at 4K.
- A 4K 4:4:4 IDR occupies the encoder for about 25–40 ms.

### Hybrid mode (host side)

The state machine in `VideoPipeline` works as follows:

1. **Changes go out as base-layer frames.** While the screen changes, every change is sent on the
   4:2:0 base layer with patch rects.
2. **Classifying changes.** A *significant* change (a large area) restarts the "sharpen" countdown.
   A small change, such as a blinking caret, a clock or a spinner, doesn't restart it. Instead its
   area is added up since the last sharp frame.
3. **When the sharp frame is sent.** The host sends one 4:4:4 IDR of the current screen on the
   sharp layer (flag bit2) in either case:
   - after a significant change, once the screen has been quiet for `sharpDelay` (200 ms by default, set with `GLIDE_SHARP_DELAY_MS`);
   - once small changes add up to more than about 3% of the screen and the screen has been quiet
     for about a second.

   While small areas keep changing, it repeats at most once every 3 s. A caret or clock
   alone never triggers a full 4:4:4 IDR.
4. **Patch after the sharp frame.** The sharp frame overwrites the whole canvas on the viewer.
   Anything captured *after* the sharp buffer was already sent on the base layer, so the host
   re-sends the rects changed since then as a base-layer patch right after the sharp frame. This
   way the canvas never regresses.
5. **Ordering.** The host never sends a sharp frame whose capture is older than the newest base
   frame already sent. That is why "apply in arrival order" on the viewer is always correct.

**Color-matched layers.** Base pixels come from SCK's 420v output and sharp pixels from BGRA.
Base-layer patches sit right next to sharp pixels on the canvas, so the two must convert
identically:

- SCK tags BGRA buffers as sRGB, which made VideoToolbox also convert the transfer curve. Dark
  grays then landed about one code value off the base layer, which showed up as faint squares
  around patches.
- The sharp buffers are re-tagged as BT.709 so VT applies only the matrix. Both layers then decode
  to the same RGB on the viewer.

### Cursor, input and power

- **Cursor:** the cursor is never part of the video. `CursorMonitor` sends `CursorShape` (BGRA
  bitmap, scaled to encoded pixels, cached by id so repeats are `CursorShapeRef`) and `CursorPos`.
  The viewer shows it as the native Windows cursor, so pointer movement has zero video latency.
- **Input:** input arrives as USB HID usages and normalized mouse coordinates. `InputInjector`
  posts CGEvents on a dedicated queue. Remapping such as Ctrl→Cmd happens on the viewer, so the
  host injects exactly what it receives.
- **Power:**
  - While the host runs, it holds a *prevent idle system sleep* assertion, because a sleeping Mac
    can't dial out or answer.
  - During an authenticated session, it holds *prevent display sleep*, since there is nothing to
    capture with the display off.
  - Mouse and keyboard input declare user activity, which wakes the display.
- **Capture failures:** capture start retries every 2 s while the display is asleep, locked or
  reconfiguring, and the session stays up meanwhile. Display-mode changes such as a HiDPI switch
  trigger a debounced re-capture with a new `VideoConfig`.
- **Which display:** the one `ActiveDisplay` resolves at each capture start, never a cached ID.
  A viewer (`SelectDisplay`) or the Mac's menu bar can select another display for the session; the
  same re-capture path then moves video and input to it, and `DisplayModeController` restores the
  old display's mode and applies its policy to the new one. When the selected display goes away
  the next re-capture falls back to the default display, and returns when it comes back
  (`DisplayChanged` tells the viewer why).

### Connection management

- **Listen mode:** `Server` runs an `NWListener`.
- **Dial mode** (`--connect` or `connect` in `host.json`): it keeps one outbound `NWConnection`
  and redials 2 s after it drops.
- Either way, the connection is handed to a new `Session`, and there is only one active session.
  On `feat/host-ux`, a connection must authenticate before it can replace the active session.

## Viewer

### Threads

The viewer (`windows/src/win/app.rs`) runs these threads:

- **UI thread:** the Win32 window and message loop, raw keyboard and mouse input, a low-level
  keyboard hook that sends Win, Alt+Tab and similar keys to the host, the cursor, fullscreen,
  and monitor and DPI tracking.
- **Render thread:** owns the D3D11 device, both Media Foundation decoders, the canvas and the
  swap chain. Frames arrive from the network over a channel and are presented as soon as they
  decode.
- **Session thread:** connects, or listens in `--listen` mode, runs one connection at a time and
  survives disconnects. While disconnected it shows a status line over the dimmed last frame,
  releases held keys, and retries every 2 s or re-listens. Each connection has its own receive
  thread and a 2 Hz ping thread from `net.rs`. The ping thread tracks RTT and the host clock
  offset: the lowest-RTT samples of a sliding 30 s window, with drift tracking (LATENCY.md).

### Decode

`win/decoder.rs` drives the Media Foundation decoder MFTs:

- HEVC comes from the HEVC Video Extension. H.264 is built in.
- Decoding runs in hardware through D3D11 (`MFT_MESSAGE_SET_D3D_MANAGER`) in low-latency mode,
  with a software fallback that copies through a staging texture.
- Output formats are NV12 or P010 for 4:2:0, and AYUV, Y410 or Y416 for 4:4:4.

Decoded frames are copied into the viewer's own shader-readable texture.

At startup, the viewer decodes small clips embedded in the exe (`windows/assets/`) to find out
what the GPU can really do. It advertises HEVC 4:4:4 (`codec_caps` bit1, which enables hybrid
mode) only if the 4:4:4 clip actually decodes.

### Canvas model (hybrid mode, viewer side)

The renderer keeps a **canvas**, an RGB10A2 texture the size of the encoded video. Every present
draws the canvas, never a decoder output directly.

- **Base-layer frames** go to decoder #1 and are always decoded, in order.
  - A non-keyframe with patch rects is converted (BT.709 limited → RGB) into the canvas through
    **scissor rects**, so only the changed rectangles are written. Pixels outside them keep
    whatever they had, which may be sharper 4:4:4 content.
  - Any other base frame replaces the whole canvas.
- **Sharp-layer frames** go to decoder #2, a separate, independent decoder with AYUV output.
  Each one is a standalone IDR that replaces the whole canvas.
- **`VideoConfig`** resets the base decoder and the canvas and invalidates the sharp layer. A new
  `SharpLayerConfig` follows it in hybrid mode.

Because the canvas persists, resizing or exposing the window re-presents it without waiting for a
new frame. The canvas is drawn aspect-fit into a waitable flip-model swap chain (maximum frame
latency 1). If the video matches the window, or fits within about 6% of it, it is drawn 1:1 and
centered rather than resampled.

### View size

- **At connect:** ClientHello reports the physical pixel size of the monitor the window is on.
- **On changes:** moving to another monitor or a DPI or display change sends `ViewSize`, debounced
  by 300 ms.
- **Host response:** the host re-captures so the encoded width is at most the view width, and
  never sends more pixels than the viewer can show 1:1. This is why the Mac's display mode should
  match the viewer monitor (see the README's troubleshooting section).

### Latency instrumentation

Every frame is timestamped at each stage on both sides: SCK PTS, capture callback, encoder
submit and output, enqueue, and send completion on the host, carried in a `FrameTiming` message
(PROTOCOL.md §3.4). On the viewer: receive, decode, canvas update, `Present()`, and the vblank
from DXGI frame statistics. `latency::Tracker` joins the two by frame id, using the
sliding-window min-RTT clock sync. The HUD shows p50s, the viewer reports them back to the host
log and menu bar, and a block-code test pattern provides ground truth. See
[LATENCY.md](LATENCY.md).

## Transport and security

The transport is TCP with `TCP_NODELAY`. Each record is a 4-byte length plus ChaCha20-Poly1305
ciphertext, with per-direction keys and counters. The details are in PROTOCOL.md §1–2.

- **Writes:** the viewer shares one encrypted writer across threads, which keeps a single send
  counter.
- **Backpressure:** the host tracks bytes in flight per connection for backpressure.

**Security v2:** a Noise_XX_25519_ChaChaPoly_SHA256 handshake between long-term keys, key pinning
on both sides, and a one-time pairing confirmed by a 6-digit code on both screens (with a host
commitment so a man in the middle can't grind matching codes). The host decides after msg3:
paired key → session, pair request in an open window → pairing, otherwise AuthResult and a
rate-limit strike. A session is "authenticated" for `SessionRegistry` only once a paired viewer's
ClientHello arrives, so pairing and rejected attempts never touch the active session. Details and
rationale: PROTOCOL.md §1–2.

## File transfer

File transfer (PROTOCOL.md §6) shares the session's connection with video and input, so it is
built to only use spare capacity:

- **Host → viewer.** `FileTransferEngine` runs on its own utility queue. It sends a chunk only
  while the connection's `bytesInFlight` (video backlog) is below 256 KiB and at most 512 KiB is
  unacknowledged; it re-checks when a chunk leaves the send queue and every 3 ms while blocked. So
  a keyframe never queues behind more than ~512 KiB of file data.
- **Viewer → host.** The viewer's `net::Sender` is shared by input, control and chunks.
  `send()` (input/control) registers itself before taking the lock; `send_bulk()` (chunks) only
  starts a record while no normal send is waiting. An input event therefore waits for at most
  the one chunk already being written (≤ 256 KiB); the ack window bounds what sits in socket
  buffers. A unit test (`net::tests::input_never_waits_behind_more_than_one_chunk`) checks this.
- **Receivers** write on their own thread/queue (never the receive path), ack each chunk after
  writing it, verify SHA-256 before renaming, and refuse peers that ignore the window.
- The viewer's `files::Service` and the host's `FileTransferEngine` are the same state machine
  (one outgoing + one incoming transfer, offer → answer → chunks/ends → done, cancel either way).

## Testing

- **Reference vectors:** three hand-written Noise implementations (Swift, Rust, Python
  `tools/glide_noise.py`) all run the official Noise vectors (`docs/noise-vectors.json`).
  `tools/gen_vectors.py` writes the Python reference transcripts (`docs/test-vectors.json`), the
  Rust tests write `docs/test-vectors-rust.json`; Swift replays both as host and viewer, Rust
  replays the Python one, Python (`--check`) replays the Rust one. CI regenerates and compares.
- **Host protocol without capture:** `GLIDE_HOST_TEST_MODE=1 glide-host --port N` with a scratch
  `GLIDE_HOST_CONFIG_DIR` runs handshake, pairing and the control socket but never captures,
  injects input or changes the display — for testing against the real viewer next to a live host.
- **End-to-end on the Mac:** `glide-probe` is a Mac-side client that uses VideoToolbox decode. It
  measures exact capture → decoded latency on loopback, can animate a test window, and dumps PNGs.
  `tools/compare.swift` builds per-tile error heatmaps from a Mac screenshot and a viewer frame dump.
- **File transfer:** `docs/file-transfer-vectors.json` (messages + adversarial names) is checked by
  all three implementations; `glide-selftest` runs the receiver/sender and an engine loopback;
  `cargo test` runs a two-service loopback; `glide-selftest --file-host PORT` is a capture-free
  host (real `SecureChannel` + `FileTransferEngine`) for end-to-end tests with the real viewer;
  `mock_host.py --file-*` covers the viewer, including adversarial offers.
- **Viewer without a Mac:** `tools/mock_host.py` plus `tools/make_streams.sh` exercise the viewer:
  - mode switches and decoder resets;
  - hybrid sharp IDRs followed by rect-limited base frames.
