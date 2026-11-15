# Controlling a Windows PC from a Mac

Glide was built for one direction: a Windows PC viewing a Mac. This document describes the
reverse direction: a **Mac viewer** (`glide-viewer`, Swift, in `mac/`) controlling a **Windows
host** (`glide-host.exe`, Rust, in `windows/`).

The wire protocol does not change. [`PROTOCOL.md`](PROTOCOL.md) defines its roles as *host* (the
machine being controlled) and *viewer* (the machine in front of you). Those roles were written with
a Mac host and a Windows viewer in mind, but nothing on the wire depends on the platform. The new
programs implement the other side of each role: the Windows host is a Noise **responder** like the
Mac host, and the Mac viewer is a Noise **initiator** like the Windows viewer.

## Status

First cut. It is built and unit-tested in CI. It has not yet had a live session on real hardware.

| Feature | Windows host | Mac viewer |
|---|---|---|
| Noise XX handshake, key pinning, pairing with a 6-digit code confirmed on both screens | yes | yes |
| Video: hardware H.264 / HEVC 4:2:0 ("fast" mode) | yes (Media Foundation) | yes (VideoToolbox) |
| `ViewSize`: host scales capture to the viewer's display | yes | yes |
| Keyboard (USB HID usages), mouse, wheel | yes (SendInput) | yes |
| Cursor shape and position | yes | yes |
| Ping / Pong | yes | yes |
| Hybrid 4:4:4 sharp layer, audio, clipboard, file transfer, display picker, input extensions | not yet | not yet |
| Dial-out from the host (§0) | not yet: the host only listens | not yet: the viewer only dials |

Capabilities the programs don't implement are simply not advertised (`codec_caps` bits, `InputCaps`,
`ClipboardCaps`, `FileCaps`), so the existing negotiation keeps each side from sending what the
other can't handle.

## Ports

The Windows host listens on **TCP 7421** by default, not 7420. A PC that also runs the Windows
viewer already listens on 7420 for a Mac host that dials in (§0), so the two programs would
otherwise collide. The Mac viewer uses 7421 when a target has no port.

## Keyboard mapping

The viewer is responsible for modifier remapping (PROTOCOL.md §3). The Mac viewer sends, by
default:

| Mac key | Sent as |
|---|---|
| Command | Control |
| Control | Windows (GUI) |
| Option | Alt |

so Mac shortcuts such as ⌘C, ⌘V and ⌘Tab-like habits land on their Windows equivalents.
`--no-remap` (or `"remapModifiers": false` in `viewer.json`) sends keys as they are.

## Files

| | Windows host | Mac viewer |
|---|---|---|
| Config | `%APPDATA%\Glide\host.json` | `~/Library/Application Support/Glide/viewer.json` |
| Identity key | `%APPDATA%\Glide\host-identity.dpapi` (DPAPI, current user) | `~/Library/Application Support/Glide/viewer-key` (64 hex chars, mode 0600) |
| Pins | `host.json` `pairedViewers` | `viewer.json` `pinnedHosts` |

## Saved connections

`viewer.json` keeps a list of saved connections:

```json
{
  "connections": [
    {
      "id": "4F0C…",
      "name": "Gaming PC",
      "platform": "windows",
      "address": "192.168.1.20:7421",
      "group": "Home",
      "favorite": true,
      "lastConnected": "2026-11-15T22:00:00Z"
    }
  ],
  "pinnedHosts": { "192.168.1.20:7421": { "key": "…", "name": "GAMING-PC", "paired": "2026-11-15T22:00:00Z" } },
  "remapModifiers": true
}
```

`platform` names the host's OS (`"windows"` or `"mac"`); a connection manager uses it to choose
defaults such as the port and the modifier mapping. `address` is `HOST[:PORT]` in one string. The
fields match the saved connections in the Windows viewer's `config.json` (`id`, `name`,
`platform`, `address`, `group`, `favorite`, `last_connected`), so both connection lists behave
the same way.
