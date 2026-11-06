# Roadmap

## Next: Security v2 (after the current feature branches merge)

> **Replace the v1 password-mixed KDF with a real PAKE (CPace or SPAKE2 over X25519) plus a pinned
> host identity.**
>
> v1 leaks a value an attacker can guess the password against offline. Any active attacker who
> impersonates either side gets it. This was found in the security review on 2026-11-06.

The v2 design:

- Run a PAKE (CPace or SPAKE2 over X25519) in place of `HKDF(shared || PBKDF2(pw))`.
- Pin a long-term host key, trusted on first use, so later sessions authenticate the host without
  relying on the password alone.
- Bump the protocol version, and update `docs/PROTOCOL.md`, `tools/gen_vectors.py` and the test
  vectors together.

Until v2 lands, these mitigations are in place:

- The password is random and 16 characters long.
- The PC firewall admits only the Mac's IP, and only to `glide-client.exe`.
- The Mac dials out, so nothing listens on the Mac.

Already fixed on `feat/host-ux`: a connection that hasn't authenticated can no longer replace the
active session.

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
  - `host.json` stores the salt, password and connect target (`--set-connect`,
    `--set-password-file`).
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
- [x] **CI:** a GitHub Actions workflow that runs:
  - the Mac release build and selftest;
  - Rust tests on Linux and Windows;
  - the MinGW cross-build, uploaded as an artifact;
  - a `--probe` smoke test;
  - the vector regeneration check.

In progress, on feature branches:

- [ ] Clipboard sync (`feat/clipboard`): text first, then images and files
- [ ] Audio (`feat/audio`): ScreenCaptureKit audio → Opus
- [ ] Viewer UX (`feat/viewer-ux`)
- [ ] Host UX (`feat/host-ux`), including the pre-auth session fix

Next:

- [ ] **Security v2** (see the top of this file)
- [ ] **Virtual display** that matches the viewer (CGVirtualDisplay), for example a 4K monitor →
  1920×1080 HiDPI at 120 Hz. This drops the BetterDisplay dependency and the need to switch modes
  with `tools/display-mode.swift`.
- [ ] **UDP video transport with NACK/FEC**, because TCP head-of-line blocking hurts on loss
- [ ] Multi-monitor support and a display picker
- [ ] Glass-to-glass latency measurement on the real LAN

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
