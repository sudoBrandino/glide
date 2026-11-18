# Installing Glide

This guide is for testers who install a prebuilt release from the
[Releases page](https://github.com/sudoBrandino/glide/releases). To build from source, see the
[README](../README.md#install-and-run) and [CONTRIBUTING.md](../CONTRIBUTING.md).

Glide has two parts:

| Part | Runs on | Release file |
|---|---|---|
| **Host** (`Glide Host.app`) | The Mac you want to control: macOS 14 or later, Apple silicon | `Glide-Host-<version>-macos-arm64.dmg` (or `.zip`) |
| **Viewer** (`glide-client.exe`) | The Windows PC you control it from: Windows 10/11 x64 | `Glide-Viewer-<version>-windows-x64.zip` |

To control a Windows PC from a Mac instead (preview), the same two downloads carry the other
side: `glide-host.exe` is in the Windows zip and `glide-viewer` is inside `Glide Host.app`
(Homebrew links it). See [WINDOWS_HOST.md](WINDOWS_HOST.md).

The host and the viewer must be the same release, or at least speak the same protocol version.
`glide-host --version` and `glide-client.exe --version` print both.

**Before you start:**

- Glide connects the two machines directly, with no relay server, on TCP port 7420. Either side
  may start the connection: the Mac and the viewer both listen *and* dial the other once they
  know its address, so one allowed direction is enough (for example a Mac on a separate network
  segment that may reach the PC, but not the other way round).
- The PC needs a GPU that decodes HEVC in hardware, plus the "HEVC Video Extensions" from the
  Microsoft Store.
  Hybrid and sharp mode need HEVC 4:4:4 decoding, which recent NVIDIA and Intel GPUs have. On
  other GPUs, Glide uses `fast` mode (4:2:0 only).
- Intel Macs are not supported. The x86_64 host compiles, but Intel Macs have no hardware
  HEVC 4:4:4 encoder, and the host doesn't fall back to fast mode on its own yet.

## Quick install

No Terminal needed. Both apps have a setup window that walks through everything below.

**Mac**

1. Download `Glide-Host-<version>-macos-arm64.dmg`, open it and drag **Glide Host** to
   **Applications**.
2. Open Glide Host from Applications. The app is signed ad hoc, not notarized, so the first time
   macOS says it can't check it: open **System Settings → Privacy & Security**, scroll down and
   click **Open Anyway**.
3. The **Glide Host Setup** window opens. From top to bottom:
   - **Start at Login**, so the Mac is reachable after a restart.
   - **Screen Recording → Allow…**, switch on Glide Host, then **Restart Glide Host** when the
     window offers it.
   - **Accessibility → Allow…**, switch on Glide Host.
   - If Glide Host isn't in the list that opens, a small panel next to System Settings shows its
     icon: drag the icon into the list, then switch Glide Host on.
   - **Connect the PC:** the window shows this Mac's address for the viewer. If your network
     only lets the Mac reach the PC, also enter the PC's address.
   - **Pair a Viewer…**, then connect from the PC: both screens show the same code; confirm on
     both.

The window opens again by itself while something is missing, and any time from the menu bar icon →
**Set Up Glide Host…**. Opening a newer download while Glide Host runs offers to replace it,
keeping the settings and pairings.

**Signing.** Releases are signed with the project's own certificate, "Glide Release Signing", so
macOS keeps the Screen Recording and Accessibility grants from one release to the next. (Builds
signed ad hoc, as pull-request builds are, need both again after every update.) It is not an Apple
Developer ID, so Gatekeeper still asks once, on the first launch. After an update, open Glide Host
once if it doesn't start at login by itself: macOS ties the login item to the exact build, and
opening the new one registers it again (replacing it from the setup window does this for you).

**Windows**

1. Download `Glide-Viewer-<version>-windows-x64.zip`, extract it and run `glide-client.exe`.
2. The setup window offers to **install** it (into `%LOCALAPPDATA%\Glide`, with a Start menu
   entry), asks for the **Mac's address** (with a **Test** button), and, if the Mac should be able
   to connect to the PC, **Allow in Windows Firewall** (one administrator prompt). **Start Glide
   when I sign in** is optional.
3. **Connect.** The first time, the pairing window shows the code to compare with the Mac.

Open the setup window again from the Glide menu or the tray icon → **Set up…**.

**From a terminal instead.** The scripts do the same, and suit scripted or remote installs:

```sh
curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/main/install.sh | bash    # Mac
brew install --cask sudobrandino/glide/glide-host && glide-setup                            # Mac, Homebrew
```

```powershell
irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1 | iex           # Windows
```

`install.sh` downloads the latest release, checks it against `SHA256SUMS` (and its build
provenance, when the GitHub CLI is installed and signed in), installs the app with a LaunchAgent,
removes an older Glide Host that would compete for the screen, walks through the permissions, the
connection (the PC's address is optional: the Mac listens either way) and pairing; `--help` lists
its options. It updates the copy that is already installed, in `/Applications` or
`~/Applications`, else installs to `~/Applications`; if that copy was set to Start at Login in its
setup window, the LaunchAgent takes over from the login item. With Homebrew, run `glide-setup`
again after each `brew upgrade` (each build needs the permissions again). `install.ps1` installs
the viewer where an existing one lives, saves the Mac's address (optional) and whether the Mac may
connect to the PC in the viewer's settings, offers the firewall rule when it may, and adds a Start
menu shortcut. Read a script before you pipe it into a shell: both are short and in this repository
([`install.sh`](../install.sh), [`install.ps1`](../install.ps1)). The sections below are the same
steps by hand.

## Contents

1. [Verify the download](#1-verify-the-download)
2. [Install the host on the Mac](#2-install-the-host-on-the-mac)
3. [Install the viewer on the PC](#3-install-the-viewer-on-the-pc)
4. [Pair and connect](#4-pair-and-connect)
5. [Update](#5-update)
6. [Uninstall](#6-uninstall)
7. [Troubleshooting](#7-troubleshooting)

## 1. Verify the download

Each release has a `SHA256SUMS` file. Download it into the same folder as the zips, then run:

```sh
# Mac (reports "OK" for each file you downloaded)
shasum -a 256 -c SHA256SUMS --ignore-missing
```

```powershell
# Windows PowerShell: compare the hash with the matching line in SHA256SUMS
Get-FileHash .\Glide-Viewer-0.2.0-windows-x64.zip -Algorithm SHA256
```

Releases built by GitHub Actions also carry a build provenance attestation. If you have the
GitHub CLI, `gh attestation verify <zip> --repo sudoBrandino/glide` checks that the file was
built from this repository by the release workflow. `install.sh` runs this check when `gh` is
installed and signed in, and doesn't install a download that fails it.

## 2. Install the host on the Mac

### 2.1 Unzip and clear the quarantine flag

The app is **signed ad hoc and not notarized** by Apple. macOS blocks such an app when it was
downloaded with a browser: it says the app "is damaged" or that Apple "could not verify" it. To
allow it, remove the quarantine flag that the browser added:

```sh
cd ~/Downloads
ditto -x -k Glide-Host-0.2.0-macos-arm64.zip .      # or double-click the zip in Finder
xattr -dr com.apple.quarantine "Glide Host.app"
mkdir -p ~/Applications
mv "Glide Host.app" ~/Applications/
```

Install it to **`~/Applications`** (the Applications folder in your home folder), which is where
the LaunchAgent below expects it. Only run `xattr` on files you have verified (step 1).

### 2.2 Start it at login (LaunchAgent)

The host runs in the background as a per-user LaunchAgent: it starts at login and restarts if it
exits. No administrator rights are needed. Pick one of the two ways below.

**Option A: with the installer, from the zip you downloaded.** It skips the download and does
the rest of the guided setup:

```sh
curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/main/install.sh \
  | bash -s -- --app ~/Downloads/Glide-Host-0.2.0-macos-arm64.zip
```

From a clone of the repository, `./install.sh --app …` does the same.

**Option B: by hand.** This creates the same LaunchAgent as `install.sh`. The label must be the
app's bundle identifier, `io.github.sudobrandino.glide.host`. `KeepAlive` restarts the host
whenever it exits, as long as the app is still there:

```sh
LABEL=io.github.sudobrandino.glide.host
APP="$HOME/Applications/Glide Host.app"
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
cat > ~/Library/LaunchAgents/$LABEL.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/glide-host</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>$APP/Contents/MacOS/glide-host</key><true/></dict>
  </dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/glide-host.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/glide-host.log</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$LABEL.plist
```

A Glide icon appears in the menu bar. The log is `~/Library/Logs/glide-host.log`; the first line
of each start names the version (`starting glide-host 0.2.0 (…), protocol v2`).

Run only one host at a time: a second `glide-host` interrupts the first one's screen capture.

### 2.3 Grant Screen Recording and Accessibility

The host needs **Screen Recording** to capture the screen and **Accessibility** to inject the
keyboard and mouse. Both must be granted to *Glide Host* itself, not to Terminal.

The host started by the LaunchAgent (section 2.2) asks for both the first time it runs: answer
the system prompts, then turn **Glide Host** on in **System Settings → Privacy & Security →
Screen Recording** and **→ Accessibility**. If it isn't listed, drag Glide Host's icon from the
panel the setup window shows next to System Settings into the list, or add it with the **+**
button (choose `Glide Host.app` in Applications).

To bring the prompts back later, launch the app through Launch Services so macOS attributes the
request to Glide Host:

```sh
open -n -a ~/Applications/Glide\ Host.app --args --request-permissions
```

Don't run the binary inside the bundle from a Terminal window for this: macOS would attribute the
request to Terminal and ask you to grant Terminal access instead.

A new Screen Recording grant only takes effect after the host restarts: menu bar → **Restart
Glide Host** (the LaunchAgent starts it again).

### 2.4 Mac firewall

If the macOS firewall is on (System Settings → Network → Firewall), macOS asks whether *Glide
Host* may accept incoming connections: the host listens on port 7420 even when it also dials the
PC. Allow it if the PC should be able to connect to the Mac. Only with `"listen": false` (see
[4.2](#42-choose-who-connects)) does nothing listen on the Mac, and then no rule is needed.

## 3. Install the viewer on the PC

1. Unzip `Glide-Viewer-0.2.0-windows-x64.zip` (right-click → **Extract All…**) into a folder
   that will stay put, for example `%LOCALAPPDATA%\Glide`. Firewall rules are tied to the exe's
   path, so don't run it from the Downloads folder or from inside the zip.
2. Run `glide-client.exe`. It is a single self-contained file; nothing else is installed.

**SmartScreen.** The exe is not code-signed, so the first run may show "Windows protected your
PC". Click **More info → Run anyway**. You can also clear the download mark before the first run:
right-click the exe → **Properties** → tick **Unblock** → OK, or in PowerShell:

```powershell
Unblock-File "$env:LOCALAPPDATA\Glide\glide-client.exe"
```

**Firewall.** Besides dialing the Mac, the viewer *listens* on TCP port 7420 so the Mac can
connect to it, unless **Let the Mac connect to this PC** is off in its setup window
(`"accept_incoming": false`, or `--no-listen`). Without the Mac's address it only listens. The
setup window's **Allow in Windows Firewall** (and `install.ps1`) adds a rule for Private networks;
otherwise Windows Defender Firewall asks the first time. Allow it on **Private** networks only.
For a tighter rule that admits only your Mac (run in an elevated PowerShell, with your path and
the Mac's address):

```powershell
New-NetFirewallRule -DisplayName "Glide viewer (from the Mac only)" -Direction Inbound `
  -Program "$env:LOCALAPPDATA\Glide\glide-client.exe" -Protocol TCP -LocalPort 7420 `
  -RemoteAddress 192.168.1.50 -Action Allow -Profile Private
```

A viewer that only dials the Mac needs no inbound rule.

When you double-click the exe, its console window closes and messages are not shown. To see them,
run it from a Command Prompt or PowerShell window. `glide-client.exe --help` lists every option,
and [`windows/README.md`](../windows/README.md) documents the config file and all flags.

Settings are in `%APPDATA%\Glide\config.json`, which is created on first run. The tray icon →
**Open config file** opens it.

## 4. Pair and connect

### 4.1 Pair once

There are no passwords. Each viewer is paired with the Mac once, by comparing a 6-digit code:

1. On the Mac: menu bar → **Pair New Viewer…**. This opens a 2-minute pairing window. (Without a
   menu bar, for example over SSH: `~/Applications/Glide\ Host.app/Contents/MacOS/glide-host --pair`.)
2. Start the viewer, or let it reconnect (see [4.2](#42-choose-who-connects)). A dialog on the PC
   shows a 6-digit code, and the Mac shows a code in an alert.
3. If the two codes match, confirm on **both** sides. If they don't, cancel: something else
   answered.

The keys are now pinned on both sides, and later connections need no interaction. Without a
screen on the Mac, run `glide-host --pair` and then, once the PC shows the code,
`glide-host --pair-code NNNNNN`; the host checks the code itself.

### 4.2 Choose who connects

Either side can open the connection, and the protocol is the same in both directions. Both sides
listen and dial at the same time, so one direction that your network allows is enough. Below,
`glide-host` stands for `~/Applications/Glide\ Host.app/Contents/MacOS/glide-host` (or the copy in
`/Applications`).

| | Mac (host) | PC (viewer) |
|---|---|---|
| **Listens** | Always, on port 7420 | On port 7420, unless **Let the Mac connect to this PC** is off (`"accept_incoming": false`, `--no-listen`) |
| **Dials the other** | Once it has the PC's address: setup window, or `glide-host --set-connect PC-ADDRESS:7420` then menu bar → Restart Glide Host | Once it has the Mac's address: setup window, `"host": "MAC-ADDRESS:7420"` in `config.json`, or `glide-client.exe MAC-ADDRESS` |

- Usually it is enough to give the viewer the Mac's address. If only the Mac can reach the PC (for
  example a Mac on a restricted network segment), also give the Mac the PC's address, and allow
  the viewer through Windows Firewall.
- `--set-connect` saves the PC's address in `~/Library/Application Support/Glide/host.json`
  (`"connect"`). The host redials every 2 seconds while disconnected. To stop dialing, clear it in
  the setup window, or remove `"connect"` from `host.json` and restart the host. With
  `"listen": false` as well, nothing listens on the Mac: only the Mac connects.
- A viewer that listens accepts only the first Mac that pairs with it (it pins that address), or
  the addresses in `"allowed_peers"` in `config.json`.
- The viewer keeps its window open across disconnects and reconnects on its own.

### 4.3 Using it

- **F11** or **Alt+Enter**: borderless fullscreen.
- Ctrl is sent as Cmd by default, so Ctrl+C copies on the Mac. `--no-ctrl-as-cmd` turns this off.
- The clipboard (text and images), Mac audio and files dragged onto the window work out of the
  box. Received files land in `~/Downloads/Glide` on the Mac and `Downloads\Glide` on the PC.
- **Ctrl+Alt+Shift+H** shows the stats overlay, and **Ctrl+Alt+Shift+Space** opens the Glide
  menu. The tray icon has a menu too (Connect, Disconnect, Forget host, Quit).

See the [README](../README.md) for display modes, file transfer and the other features.

### 4.4 The virtual display (on by default)

When a viewer connects, the host creates a **virtual display** with exactly the viewer's pixel
size and refresh rate and streams it 1:1, which gives the sharpest picture and the lowest latency.
What you see on the Mac itself:

- **A laptop with the lid open and no external monitor:** nothing changes on the Mac. Glide
  streams the built-in display as it is, scaled to fit the PC's window.
- **With an external monitor attached**, the monitor **mirrors** the virtual display for
  the length of the session, so it briefly changes resolution when you connect. Your windows,
  menu bar and Dock stay where they are. About 10 seconds after the viewer disconnects, the
  mirror ends and the monitor goes back to its own mode. If the monitor's current mode already
  matches the viewer exactly, Glide streams the monitor directly and creates nothing.
- **Headless Mac or lid closed:** the virtual display is the Mac's screen while you're connected.

Quitting or restarting Glide Host ends the mirror, puts the monitor's mode back and removes the
virtual display. Nothing Glide changes survives logging out.

To turn it off: menu bar → **Virtual Display** → untick **Use a Virtual Display Sized to the
Viewer**, or in
`~/Library/Application Support/Glide/host.json`:

```json
"virtualDisplay": { "enabled": false }
```

The menu also offers **Stream the Monitor Instead** (the pre-0.2 behavior: the host switches the
monitor to a mode that suits the viewer) and **Extend: Place It Beside the Monitor** (the virtual
display sits beside the monitor instead of being mirrored).

The virtual display uses macOS's `CGVirtualDisplay`, an undocumented API that a macOS update may
change; if it's unavailable, Glide logs why and streams the monitor. To check it on your Mac
before connecting (creates a test display for about 20 s; windows may move meanwhile):

```sh
~/Applications/Glide\ Host.app/Contents/MacOS/glide-host --virtual-display-selftest
```

Details: [VIRTUAL_DISPLAY.md](VIRTUAL_DISPLAY.md).

## 5. Update

Run the installer again (`install.sh` or `install.ps1`, see [Quick install](#quick-install)), or
`brew upgrade glide-host && glide-setup`. By hand:

1. Mac: unzip the new app and clear its quarantine flag ([2.1](#21-unzip-and-clear-the-quarantine-flag)).
   Quit the old host (menu bar → **Quit Until Next Login**, which unloads the LaunchAgent),
   replace `~/Applications/Glide Host.app`, and load the agent again:
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.sudobrandino.glide.host.plist`
   (or log out and back in).
2. Because the app is signed ad hoc, macOS treats each release as a new app and may ignore the
   old permissions. If capture or input stops working, remove *Glide Host* from **Screen
   Recording** and **Accessibility** in System Settings (the **−** button), then repeat
   [2.3](#23-grant-screen-recording-and-accessibility).
3. PC: close the viewer and replace `glide-client.exe` at the same path, so firewall rules keep
   applying.

Pairings and settings survive updates.

## 6. Uninstall

**Mac.** `install.sh --uninstall` (or `glide-setup --uninstall`) does the first three lines, and
`--purge` the rest; with Homebrew, `brew uninstall --zap glide-host`. By hand:

```sh
launchctl bootout gui/$(id -u)/io.github.sudobrandino.glide.host
rm -f ~/Library/LaunchAgents/io.github.sudobrandino.glide.host.plist
rm -rf ~/Applications/Glide\ Host.app
# Optional: settings, this Mac's key and the paired viewers; the log; the privacy grants
rm -rf ~/Library/Application\ Support/Glide ~/Library/Logs/glide-host.log
tccutil reset ScreenCapture io.github.sudobrandino.glide.host
tccutil reset Accessibility io.github.sudobrandino.glide.host
```

**PC.** Run the installer with `-Uninstall` (add `-Purge` for the settings):
`& ([scriptblock]::Create((irm https://raw.githubusercontent.com/sudoBrandino/glide/main/install.ps1))) -Uninstall`.
By hand: quit the viewer (tray → **Quit Glide**), turn off **Start Glide when I sign in** in its
setup window, delete its folder and its Start menu shortcut, and optionally delete
`%APPDATA%\Glide` (settings, this PC's key, the pinned Mac key) and any firewall rule you added.

## 7. Troubleshooting

Look at the logs first: on the Mac, menu bar → **Open Log** (`~/Library/Logs/glide-host.log`); on
the PC, run `glide-client.exe` from a terminal to see its messages.

| Symptom | What to do |
|---|---|
| macOS says *Glide Host* "is damaged" or "can't be opened" | The quarantine flag is still set: `xattr -dr com.apple.quarantine ~/Applications/Glide\ Host.app` ([2.1](#21-unzip-and-clear-the-quarantine-flag)) |
| No menu-bar icon | Check that the agent is loaded: `launchctl print gui/$(id -u)/io.github.sudobrandino.glide.host`. Read the log for errors |
| Black screen, or "Screen recording NOT granted" in the log | Grant Screen Recording ([2.3](#23-grant-screen-recording-and-accessibility)), then **Restart Glide Host**. After an update, remove and re-add the grant |
| The picture works but the mouse and keyboard don't | Grant Accessibility to *Glide Host* ([2.3](#23-grant-screen-recording-and-accessibility)) |
| "capture unavailable" in the log | The display is asleep, locked or being reconfigured. The host wakes it and retries every 2 s |
| Viewer: "Not paired" or "doesn't recognize this PC" | Open the pairing window on the Mac (**Pair New Viewer…**). The viewer keeps retrying |
| Viewer: "HOST KEY CHANGED" | The Mac presented a different key from the one you paired. If you reset or reinstalled the Mac's Glide settings, use tray → **Forget host (unpair)…** and pair again. Otherwise, treat it as an impersonation attempt |
| A message about protocol v1, or "unsupported protocol version" | The other side runs an older build. Install the same release on both |
| The viewer waits forever ("Waiting for host on port 7420…") | It has no Mac address, so it only listens. Enter the Mac's address (Glide menu or tray → **Set up…**), or give the Mac the PC's address (its setup window, or `--set-connect`). Check the Windows firewall rule |
| Can't connect to the Mac | Check the address and that port 7420 is reachable (`Test-NetConnection MAC-ADDRESS -Port 7420` in PowerShell), and the macOS firewall ([2.4](#24-mac-firewall)) |
| No hybrid or sharp mode, or no picture at all | Install the HEVC Video Extensions. `glide-client.exe --probe` prints what the GPU can decode |
| Blurry picture | See *Blurry picture* in the README's [Troubleshooting](../README.md#troubleshooting) section |

When you report a bug, include `glide-host --version`, `glide-client.exe --version`, the Mac and
GPU models, and the relevant log lines. Report security problems privately, as described in
[SECURITY.md](../SECURITY.md).
