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

## Known limits on the Windows host

- **Secure desktop:** UAC prompts and the lock screen can't be seen or controlled. Capturing them
  needs a service running as SYSTEM; the host logs and retries until the normal desktop returns.
- **Elevated windows:** Windows blocks input to windows running as administrator unless
  `glide-host.exe` itself runs elevated.
- **Primary display only**, and whole frames are encoded when the screen changes (no dirty-rect
  patches yet).
- Cursor shapes are scaled to encoded pixels, as the Mac host does.

See [`windows/README.md`](../windows/README.md) for `glide-host.exe` flags, the tray menu and the
console commands.

## Managed mode

In an organization using Glide Cloud ([`ENTERPRISE.md`](ENTERPRISE.md)), Group Policy or Intune sets
`CloudURL` and `EnrollmentToken` under `HKLM\SOFTWARE\Policies\Glide`. `glide-host.exe` then enrolls the PC,
stays connected to the organization's hub over HTTPS (system proxy and certificate store, through WinHTTP)
and accepts **relayed** sessions from signed-in users the organization's policies allow, without pairing
and without an open inbound port:

- With `approval: required` the PC asks "NAME (email) from your organization asks to see and control this
  PC" (Decline is the default; it declines by itself after 50 s). Otherwise it accepts unless another
  session is running.
- The viewer key the cloud grants is accepted for that one session only, and never added to the paired
  Macs.
- The session's permissions apply here too: a view-only session can't send input, and clipboard and file
  data are refused in directions the session doesn't allow.
- While a managed session runs, the tray says "NAME (email) is connected" and offers **End session**.
- The organization can turn LAN mode off (the host stops listening on 7421) and local pairing off (Pair New
  Mac… is disabled). `DisableLANMode` = 1 in the policy key turns LAN mode off locally.

See [`windows/README.md`](../windows/README.md#managed-mode-glide-cloud) for the details.

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
Turn off **Map Mac modifier keys to PC keys** in Settings (`"remapModifiers": false` in
`viewer.json`) to send keys as they are; the change applies to a running session at once.
`--no-remap` turns mapping off for one run.

## Using the Mac viewer

`glide-viewer` with no arguments opens the **Connections** window and never connects on its own.
`glide-viewer NAME|HOST[:PORT]` connects straight away (`--pair`, `--no-remap`, `--fullscreen`),
and `glide-viewer --forget HOST[:PORT]` unpairs from the command line.

**Connections** (Connection → Connections…, ⌘0) lists the saved connections with their address,
pairing state ("Paired with GAMING-PC", "Not paired yet") and when each was last used, grouped by
group with favorites first. Type in the search field to filter by name, address or group.

| Action | How | What it does |
|---|---|---|
| Connect | Return, double-click, **Connect** | Opens a session window; the Connections window hides |
| Add | **Add…**, Connection → New Connection… (⌘N) | Name, address, port (blank = 7421), group, favorite |
| Edit | **Edit…**, right-click | Same form. A blank name becomes the address; names are unique (case-insensitive) |
| Duplicate | **Duplicate**, right-click | A copy named "NAME (copy)", never used |
| Remove | **Remove…**, Delete key, right-click | Asks first. Also forgets the pinned PC key, unless another saved connection uses the same address |
| Unpair | **Unpair…**, right-click | Asks first. Forgets the pinned PC key; the next connection pairs again with a 6-digit code |

These follow the same rules as the Windows viewer's Connections window. An address that doesn't
parse, or a connection whose `platform` this viewer doesn't know, is listed but can't be opened.

**Disconnect** (Connection → Disconnect, ⇧⌘D, or closing the session window) ends the session and
returns to the Connections window, also when the session was started from the command line.
Quit with ⌘Q. While a session is streaming, keyboard shortcuts go to the PC, so use the menu bar
with the mouse.

**Settings** (Glide Viewer → Settings…, ⌘,):

- **Map Mac modifier keys to PC keys** (`remapModifiers`, on by default): see
  [Keyboard mapping](#keyboard-mapping).
- **Open sessions in full screen** (`startFullScreen`, off by default). `--fullscreen` forces it
  for one run.
- **This Mac's viewer key:** the fingerprint the PC shows in its pairing dialog, with a **Copy**
  button, and a button that shows `viewer.json` in Finder.

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
  "remapModifiers": true,
  "startFullScreen": false
}
```

`platform` names the host's OS (`"windows"` or `"mac"`); the viewer uses it to choose the default
port (7421 for Windows, 7420 for a Mac). Connections added in the Connections window are
`"windows"`; editing one keeps its platform. Older files without `startFullScreen` read as off. `address` is `HOST[:PORT]` in one string. The
fields match the saved connections in the Windows viewer's `config.json` (`id`, `name`,
`platform`, `address`, `group`, `favorite`, `last_connected`), so both connection lists behave
the same way.
