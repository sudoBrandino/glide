# Roadmap

## v0 — LAN prototype (in progress)
- [x] Protocol spec + reference vectors (Python) reproduced by Swift
- [x] Mac host: SCK capture, VT HEVC/H.264 (4:2:0 LL, 4:4:4), latest-frame-wins scheduling,
      backpressure, idle refinement re-encodes, CGEvent input, cursor shapes, dial-out mode
- [x] Mac probe client (VT decode, exact loopback latency, PNG dump, listen mode)
- [ ] Windows viewer: MF decode, D3D11 render, input, cursor (agent building)
- [ ] First real Win → Mac session, measure glass-to-glass

## v1 — daily-driver quality
- [ ] Hybrid sharpness: 4:2:0 low-latency while moving, a 4:4:4 refinement keyframe once the
      screen settles (needs a second decoder on the viewer) — RustDesk can't do this on Mac
- [ ] Virtual display that matches the viewer (CGVirtualDisplay): e.g. 4K monitor →
      1920×1080 HiDPI at 120 Hz; drop BetterDisplay dependency
- [ ] UDP video transport with NACK/FEC (TCP head-of-line blocking on loss)
- [ ] Clipboard sync (text, then images/files), audio (SCK audio → Opus)
- [ ] Multi-monitor, display picker
- [x] Signed `.app` bundle + LaunchAgent so TCC permissions stick to the host, menu-bar UI
- [x] Automatic display-mode policy (match the viewer: crisp 1x / Retina HiDPI), restore on disconnect
- [ ] Windows viewer UI: connection list, settings, HUD

## v2 — beyond the LAN
- [ ] Rendezvous/relay server (self-hosted, e.g. on the home server) for NAT traversal
- [ ] SPAKE2 pairing + pinned host keys (replaces password-mixed KDF; removes offline
      dictionary attack by an active MITM)
- [ ] File transfer

## Known issues
- VideoToolbox rejects `MaxFrameDelayCount` and `PrioritizeEncodingSpeedOverQuality` in
  low-latency mode (harmless; logged).
- Network: the Mac lives on the Admin VLAN (192.168.50.0/29); Trusted → Admin is blocked by the
  UniFi zone firewall, so the Mac dials the viewer (`--connect`). The PC has a Windows Firewall
  rule allowing only 192.168.50.4 → glide-client.exe.
