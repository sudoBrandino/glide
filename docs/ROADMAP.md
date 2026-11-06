# Roadmap

## Security v2 (done)

The v1 password handshake leaked a value an active impostor could test password guesses against
offline (security review, 2026-11-06). v2 replaces it (PROTOCOL.md §1–2):

- Noise_XX_25519_ChaChaPoly_SHA256 between long-term keys (Mac: `host-key` file; PC: DPAPI).
- Key pinning both ways; pairing confirmed with a 6-digit code on both screens (host commitment +
  nonces against code grinding); menu-bar alert or `glide-host --pair`/`--pair-code` headless.
- Version negotiation (`GLD2`), clear errors across v1/v2, per-address rate limiting, wall-clock
  pre-auth deadlines.
- A PAKE was rejected: CryptoKit has no raw curve operations.

Possible follow-ups: move the host key into the Keychain once the app has a provisioning profile
(data-protection keychain); show the pairing code on the Mac via a notification as well.

## v0 — LAN prototype (done)

- [x] Protocol spec plus reference vectors (Python), reproduced by Swift and Rust
- [x] Mac host:
  - ScreenCaptureKit capture
  - VideoToolbox HEVC/H.264 (4:2:0 low-latency, 4:4:4)
  - latest-frame-wins scheduling, backpressure, idle refresh re-encodes
  - CGEvent input, cursor shapes
- [x] Mac probe client: VideoToolbox decode, exact loopback latency, PNG dump, listen mode
- [x] Windows viewer:
  - Media Foundation hardware decode, D3D11 flip-model rendering
  - raw input with a low-level keyboard hook, Ctrl→Cmd remap
  - native cursor, borderless fullscreen
  - `--probe` and `--bench`
- [x] First real Windows → Mac sessions over the LAN

## v1 — daily-driver quality

Done:

- [x] **Dial-out mode:** `glide-host --connect` with auto-redial, and `glide-client --listen`.
  This is for networks that only allow host → viewer connections, such as the admin VLAN.
- [x] **Hybrid sharpness:**
  - 4:2:0 low-latency while the screen moves, a standalone 4:4:4 IDR once it settles.
  - The viewer runs a second decoder, and both layers feed an RGB canvas.
  - Pixel-diff (`TileDiff`) patch rects, applied through scissor rects.
  - A post-sharp patch so the canvas never regresses.
  - Color-matched layers: BT.709 tagging, so there are no seams between patches and sharp pixels.
  - Encode takes about 10–12 ms at 2560×1440 and about 18 ms at 4K.
- [x] **App bundle and LaunchAgent:**
  - The signed `Glide Host.app` keeps its privacy (TCC) grants across rebuilds.
  - `tools/make-host-app.sh` and `tools/install-host.sh` build and install it.
  - `--request-permissions`.
  - `host.json` stores the connect target (`--set-connect`) and, since security v2, the paired
    viewers.
- [x] **Power management:** no idle system sleep while hosting, no display sleep during a session,
  display wake on input, and capture retries while the display is asleep or locked.
- [x] **ViewSize:**
  - The viewer reports its current monitor's physical size and updates it when it changes.
  - The host re-captures to match, with no resampling at 1:1.
  - Display-mode changes on the Mac trigger a re-capture.
- [x] **Viewer auto-reconnect:**
  - The window survives disconnects and shows a status overlay over the dimmed last frame.
  - It releases held keys, then retries or re-listens.
  - Fullscreen is kept across reconnects.
- [x] **Clipboard sync:** text + images (PNG) both directions with loop/echo suppression
  (PROTOCOL.md §5).
- [x] **Audio:** ScreenCaptureKit system audio on the base capture stream → PCM s16le 48 kHz
  stereo → WASAPI through a drift-correcting jitter buffer (PROTOCOL.md §3.2). Mute with Ctrl+F11.
- [x] **CI:** a GitHub Actions workflow that runs:
  - the Mac release build and selftest;
  - Rust tests on Linux and Windows;
  - the MinGW cross-build, uploaded as an artifact;
  - a `--probe` smoke test;
  - the vector regeneration check.

In progress, on feature branches:

- [ ] Viewer UX (`feat/viewer-ux`)
- [x] Host UX (merged): menu-bar status item, automatic display-mode policy (crisp 1x / Retina
  HiDPI to match the viewer, restore on disconnect), auth-gated session replacement, pending
  connections evict-oldest with a per-source limit

Next:

- [x] **Security v2** (see the top of this file)
- [ ] **Virtual display** that matches the viewer (CGVirtualDisplay), for example a 4K monitor →
  1920×1080 HiDPI at 120 Hz. This drops the BetterDisplay dependency and the need to switch modes
  with `tools/display-mode.swift`.
- [ ] **UDP video transport with NACK/FEC**, because TCP head-of-line blocking hurts on loss
- [ ] Multi-monitor support and a display picker
- [ ] Glass-to-glass latency measurement on the real LAN
- [ ] Clipboard: files (with file transfer); chunked transfer so big images don't stall video
- [ ] Audio: Opus (codec 2) for non-LAN links; needs a Windows decoder that builds with MinGW

## v2 — beyond the LAN

- [ ] A self-hosted rendezvous or relay server, for example on the home server, for NAT traversal
- [ ] File transfer

## Known issues

- VideoToolbox rejects `MaxFrameDelayCount` and `PrioritizeEncodingSpeedOverQuality` in
  low-latency mode. This is harmless and only logged.
- Only one host process can capture at a time. A second ScreenCaptureKit stream interrupts the
  first. Stop the LaunchAgent before you run a host from the shell.
- `swift build` with the default build backend fails on a Command Line Tools-only setup. Use
  `--build-system native` there. It works with Xcode, which is what CI uses.
- **Network:**
  - The Mac is on the admin VLAN (192.168.50.0/29). Trusted → Admin is blocked by the UniFi zone
    firewall, so the Mac dials the viewer (`--connect`, or `connect` in `host.json`).
  - The PC has a Windows Firewall rule that allows only 192.168.50.4 → `glide-client.exe`.
