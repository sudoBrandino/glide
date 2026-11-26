# Deploying Glide in an organization

This guide is for IT administrators who roll Glide out to managed Macs and PCs and connect it to
the organization's **Glide Cloud** tenant: single sign-on, central policies, relayed sessions
without open ports, and an audit log. How managed mode works is specified in
[ENTERPRISE.md](ENTERPRISE.md); what it protects in [THREAT_MODEL.md](THREAT_MODEL.md#managed-mode-glide-cloud).
For a single personal install, see [INSTALL.md](INSTALL.md) instead.

## Contents

1. [What you deploy](#1-what-you-deploy)
2. [Prerequisites](#2-prerequisites)
3. [Macs: Jamf, Intune, Kandji](#3-macs)
4. [Windows: Intune, Group Policy, Configuration Manager](#4-windows)
5. [Network](#5-network)
6. [Verify](#6-verify)
7. [Update](#7-update)
8. [Uninstall](#8-uninstall)

## 1. What you deploy

From each [release](https://github.com/sudoBrandino/glide/releases):

| File | Installs | Signed |
|---|---|---|
| `Glide-Host-<version>-macos-arm64.pkg` | `/Applications/Glide Host.app` (lets the Mac be controlled; also carries the `glide-viewer` command) and the LaunchAgent `/Library/LaunchAgents/dev.brandino.glide.host.plist`, which starts it in every user's session | Developer ID Installer; the app with Developer ID Application, hardened runtime; notarized and stapled |
| `Glide-Viewer-<version>-macos-arm64.pkg` | `/Applications/Glide Viewer.app` (controls a Windows PC from the Mac) | as above |
| `Glide-<version>-windows-x64.msi` | `C:\Program Files\Glide\glide-client.exe` (viewer: controls a Mac) and `glide-host.exe` (lets the PC be controlled), Start menu shortcuts, optional firewall rules and sign-in start | Authenticode (Azure Artifact Signing), timestamped |
| `SHA256SUMS` | checksums of every file | build provenance attestation: `gh attestation verify <file> --repo sudoBrandino/glide` |

And from this repository:

| Path | What |
|---|---|
| [`packaging/mdm/`](../packaging/mdm/) | macOS configuration profiles: PPPC (privacy permissions), managed preferences, managed login items; [`tools/fill-mdm-profiles.sh`](../tools/fill-mdm-profiles.sh) fills them in |
| [`packaging/windows/admx/`](../packaging/windows/admx/) | Group Policy / Intune administrative templates (`Glide.admx`, `en-US/Glide.adml`) |

A device becomes managed as soon as it finds a **Glide Cloud URL** and an **enrollment token** in
its managed configuration: it enrolls itself on start, and from then on its sessions go through
Glide Cloud. Each app installation is its own device (a Mac with both apps is two devices).

## 2. Prerequisites

- **A Glide Cloud organization.** The operator creates it and sends a one-time setup link for its
  first owner ([ENTERPRISE.md §5.4](ENTERPRISE.md#54-org-onboarding-operator-provisioned)). In the
  admin console:
  1. **Single sign-on:** register Glide Cloud as an OIDC app in your identity provider (Microsoft
     Entra ID, Okta, Google Workspace…) with the redirect URI the console shows, and enter the
     issuer, client ID and secret. Optionally map IdP groups to console roles.
  2. **Policies:** who may reach which hosts, with which permissions, and whether the person at
     the host must approve ([ENTERPRISE.md §8](ENTERPRISE.md#8-access-policies)).
  3. **Org settings:** for example LAN mode off, so managed devices only accept Glide Cloud
     sessions.
  4. **An enrollment token** (Enrollment tokens → New), ideally with an expiry or a maximum
     number of uses and default tags. It goes into the MDM configuration; treat it as a secret.
- **The Cloud URL** of your tenant, e.g. `https://glide.example.com`.
- **Macs:** macOS 14 or later, Apple silicon; enrolled in an MDM (user-approved or Automated
  Device Enrollment, which PPPC profiles require).
- **PCs:** Windows 10 or 11, x64. Viewers need a GPU with HEVC hardware decoding and the "HEVC
  Video Extensions" from the Microsoft Store (deploy them through the Microsoft Store app in
  Intune, or your usual Store channel).
- **Network:** outbound HTTPS to the Cloud URL's host name ([§5](#5-network)).

## 3. Macs

Overview (the MDM-specific steps are in [packaging/mdm/README.md](../packaging/mdm/README.md)):

1. **Fill in the profiles** for your tenant from the release you deploy:

   ```sh
   tools/fill-mdm-profiles.sh --cloud-url https://glide.example.com --token "<enrollment token>" \
     --org "Example Corp" Glide-Host-<version>-macos-arm64.pkg out/
   ```

   This writes `glide-pppc.mobileconfig` with the host's real code requirement (bundle id
   `dev.brandino.glide.host` and Glide's Developer ID team), `glide-login-items.mobileconfig`,
   `glide-managed-preferences.mobileconfig` and `dev.brandino.glide.plist`. Managed preference
   keys (domain `dev.brandino.glide`): `CloudURL`, `EnrollmentToken`, `DeviceName`, `Tags`,
   `DisableLANMode`.
2. **Upload and scope the profiles** first: PPPC, managed login items, managed preferences.
3. **Deploy the pkg(s)**: Glide Host on Macs that people connect *to*; Glide Viewer on Macs used
   to control Windows PCs.

| | Jamf Pro | Microsoft Intune | Kandji |
|---|---|---|---|
| pkg | Packages + Policy (Enrollment Complete, Recurring Check-in, once per computer) | Apps → macOS app (PKG) | Library → Custom App (installer package) |
| PPPC | Configuration Profile: upload, or PPPC payload | Devices → Configuration → Templates → Custom (upload) | Library → Privacy, or Custom Profile |
| Login items | Upload, or Managed Login Items payload (Label rule) | Custom profile (upload) | Custom Profile, or Login & Background Items |
| Settings | Application & Custom Settings (domain `dev.brandino.glide`, `$COMPUTERNAME` allowed) or upload | Templates → Preference file (domain `dev.brandino.glide`) | Custom Profile (`$DEVICE_NAME` allowed) |

What the user still does: **Screen Recording.** Apple does not let an MDM grant it; the PPPC
profile only allows a *standard* user to switch it on. At the first start, Glide Host's setup
window shows **Screen Recording → Allow…**, which opens the right page in System Settings. Until
then the Mac can enroll and be listed, but sessions show no picture. Accessibility (remote input)
is granted by the profile.

The pkg's postinstall starts the host for whoever is logged in, removes per-user LaunchAgents left
by earlier personal installs (including the label `io.github.sudobrandino.glide.host` of releases up to 0.4.x) and
turns off the app's own login item, so exactly one host runs. Settings and pairings in
`~/Library/Application Support/Glide` are kept. Its log is in `/var/log/install.log`.

## 4. Windows

### 4.1 The MSI

Per-machine install to `C:\Program Files\Glide`. Properties:

| Property | Effect |
|---|---|
| `CLOUDURL=https://glide.example.com` | `HKLM\SOFTWARE\Policies\Glide\CloudURL` (REG_SZ) |
| `ENROLLMENTTOKEN=<token>` | `…\EnrollmentToken` (REG_SZ); hidden from MSI logs |
| `DEVICENAME=<name>` | `…\DeviceName` (REG_SZ); default: the computer name |
| `DISABLELANMODE=1` | `…\DisableLANMode` (REG_DWORD 1), and the firewall rules are left out |
| `AUTOSTART=1` | start the viewer at every user's sign-in (it opens without connecting) |
| `HOSTAUTOSTART=1` | start `glide-host.exe` at every user's sign-in: needed for PCs people connect *to* |

Without `DISABLELANMODE=1` the MSI adds inbound Windows Firewall rules for LAN connections,
scoped to the two programs, Domain and Private profiles: `glide-client.exe` TCP 7420,
`glide-host.exe` TCP 7421. Managed sessions don't need them (they are outbound only).

```bat
msiexec /i Glide-<version>-windows-x64.msi CLOUDURL=https://glide.example.com ENROLLMENTTOKEN=<token> HOSTAUTOSTART=1 /qn /l*v "%TEMP%\glide-msi.log"
```

Values given at install are kept across upgrades (an upgrade without the properties keeps them)
and removed on uninstall. Values set by Group Policy or Intune (ADMX) take the same registry
places; prefer one channel per value. Tags have no MSI property: set them by policy (§4.3) or as
the enrollment token's default tags.

Tip: machine policy is read before user policy. The enrollment values come as one set from the
first scope that has a `CloudURL`, and `DisableLANMode` applies if either scope sets it
([ENTERPRISE.md §11.2](ENTERPRISE.md#112-windows)).

### 4.2 Intune

1. **App:** Apps → Windows → Add → **Line-of-business app** → upload the MSI. Command-line
   arguments: `CLOUDURL=https://glide.example.com ENROLLMENTTOKEN=<token> HOSTAUTOSTART=1`.
   Install context: *Device*. Assign as *Required*. (For more control over detection and
   updates, wrap it as a **Win32 app** with the Microsoft Win32 Content Prep Tool; install
   command as in §4.1, uninstall `msiexec /x {ProductCode} /qn`, detection rule: MSI product
   code, or the registry value `HKLM\SOFTWARE\Glide\Installer\Version`.)
2. **Settings by policy instead (or as well):** Devices → Configuration → Create → Windows 10
   and later → **Templates → Imported Administrative templates**; first import `Glide.admx` and
   `en-US/Glide.adml` under Devices → Configuration → Import ADMX. Then configure *Glide* → Glide
   Cloud URL, Enrollment token, Device name, Device tags, Turn off LAN mode, under Computer
   Configuration.
3. HEVC Video Extensions for viewers: Apps → Microsoft Store app (new).

### 4.3 Group Policy

1. Copy `Glide.admx` to the Central Store
   (`\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions`) and `en-US\Glide.adml` to its
   `en-US` folder.
2. In a GPO: Computer Configuration → Policies → Administrative Templates → **Glide**: set
   *Glide Cloud URL*, *Enrollment token*, optionally *Device name* (rarely useful machine-wide),
   *Device tags*, *Turn off LAN mode*. The same policies exist under User Configuration.
3. Software installation: Computer Configuration → Policies → Software Settings → Software
   installation → New → Package → the MSI on a share readable by computer accounts → *Assigned*.
   Assigned packages take no command-line properties: set the values with the ADMX policies
   above (recommended), or build a transform (`.mst`) with Orca that sets the properties and
   add it on the Modifications tab.

### 4.4 Configuration Manager (SCCM / MECM)

1. Software Library → Applications → Create Application → **Windows Installer (\*.msi file)**
   from a share; ConfigMgr reads the product code for detection.
2. Edit the deployment type's installation program:
   `msiexec /i "Glide-<version>-windows-x64.msi" CLOUDURL=https://glide.example.com ENROLLMENTTOKEN=<token> HOSTAUTOSTART=1 /qn`;
   install behavior *Install for system*, *Whether or not a user is logged on*.
3. For a new release, create a new application and set **supersedence** on the old one
   (*Uninstall* unchecked: the MSI's MajorUpgrade replaces it).

`install.ps1` (the personal installer) detects an MSI install and leaves it alone, so users who
run it don't end up with a second copy.

## 5. Network

Managed mode needs **outbound TCP 443 to the Cloud URL's host name, and nothing else**: the API,
the device hub (a WebSocket) and the session relay (a WebSocket) all live there. Nothing listens
for inbound connections for managed sessions, so no port forwarding, VPN or inbound firewall rule
is needed. Users signing in on a viewer also reach your identity provider in their browser, as for
any SSO app.

- **Proxies.** macOS uses the system proxy settings (including PAC and WPAD) through
  `URLSession`; Windows uses the system proxy settings through WinHTTP (automatic proxy on
  Windows 8.1 and later). The proxy must allow WebSocket upgrades (`Upgrade: websocket`, long-lived
  connections) to the Cloud URL's host; idle connections carry a ping every 30 seconds.
  Proxies that require interactive or NTLM/Kerberos authentication per app are not supported:
  exempt the host name from authentication.
- **TLS inspection.** The apps validate TLS against the operating system's trust store, so an
  inspection proxy whose root certificate is deployed to the devices works for the API. Session
  contents stay end-to-end encrypted by Glide's own Noise layer either way: inspection sees only
  opaque bytes, and a proxy can't impersonate a device. Inspection proxies often break or buffer
  WebSockets, though; if sessions fail to start or stall, **exempt the Cloud URL's host from
  inspection**.
- **Bandwidth.** A session is a video stream through the relay. With the automatic bitrate the
  encoder aims at about 0.2 bits per pixel per frame while the screen changes: roughly 25 Mbit/s
  at 1080p and 60 fps, up to about 100 Mbit/s at 4K, and far less for a still screen.
- **LAN mode** (direct connections, as in personal use) uses TCP 7420 (Mac host; Windows viewer)
  and 7421 (Windows host) inside the network. Turn it off by org setting or `DisableLANMode` if
  you want every session to go through Glide Cloud's sign-in, policy and audit.

## 6. Verify

**Mac:**

```sh
sudo profiles show -type configuration | grep -A3 dev.brandino.glide
defaults read "/Library/Managed Preferences/dev.brandino.glide"
pkgutil --pkg-info dev.brandino.glide.host.pkg
launchctl print "gui/$(id -u)/dev.brandino.glide.host" | grep -E 'state|pid'
grep cloud ~/Library/Logs/glide-host.log | tail
```

The host's menu bar menu says "Managed by <organization>" once it has enrolled.

**Windows** (PowerShell):

```powershell
Get-ItemProperty HKLM:\SOFTWARE\Policies\Glide
Get-ItemProperty HKLM:\SOFTWARE\Glide\Installer
Get-AuthenticodeSignature "C:\Program Files\Glide\glide-client.exe" | Format-List Status, SignerCertificate
Get-NetFirewallRule -DisplayName 'Glide*' | Format-Table DisplayName, Profile, Enabled
```

**Console:** the devices appear under Devices with their platform, version and tags. Start a test
session from a viewer (sign in when it asks), and check that the audit log shows
`device.enrolled`, `user.signed_in`, `session.requested`, `session.started` and `session.ended`.

Common problems:

| Symptom | Check |
|---|---|
| Device never appears | Cloud URL reachable (`curl -I https://glide.example.com/` from the device, through the same proxy); token valid, not expired or used up; on a Mac, the host's log (`~/Library/Logs/glide-host.log`, lines with `cloud:`) |
| "host offline" | The host app runs (Mac: LaunchAgent; Windows: `HOSTAUTOSTART=1` or start it); WebSockets allowed by the proxy |
| Session starts but stays black (Mac) | Screen Recording not yet allowed by the user |
| No remote input (Mac) | PPPC profile installed and its code requirement matches the deployed app (`codesign -dr - "/Applications/Glide Host.app"`) |
| SmartScreen warning on Windows | The file is signed (check above); a new signing identity needs some downloads to build reputation |

## 7. Update

Deploy the newer pkg or MSI the same way; both upgrade in place and keep settings, enrollment and
pairings. On the Mac the pkg replaces the app and restarts the host; the Screen Recording grant
carries over because the code requirement doesn't change between releases. The Windows MSI's
fixed UpgradeCode makes every release replace the previous one (MajorUpgrade); keep the same
properties, or none (they are remembered).

An org setting `min_app_version` in the console makes older apps refuse managed sessions with
"update required".

## 8. Uninstall

**Mac:** run, as root (an MDM script or policy):

```sh
"/Applications/Glide Host.app/Contents/Resources/glide-uninstall" --purge
```

It stops the host for every logged-in user, removes the LaunchAgents, both apps and the package
receipts; `--purge` also removes every user's Glide settings, keys, enrollment and log and
resets the privacy grants (`--keep-viewer` keeps Glide Viewer.app). Then remove the
configuration profiles in the MDM. Revoke the devices in the console so their enrollment can't
be reused.

**Windows:** uninstall the MSI (Intune: assign *Uninstall*; ConfigMgr: an uninstall deployment;
GPO: remove the package with *Immediately uninstall*), or by hand:

```powershell
$p = Get-ChildItem HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall |
  Get-ItemProperty | Where-Object DisplayName -eq 'Glide'
Start-Process msiexec.exe -Wait -ArgumentList "/x $($p.PSChildName) /qn"
```

This removes the programs, shortcuts, firewall rules, sign-in entries and the policy values the
MSI wrote (values set by Group Policy or Intune stay until the policy is removed). Each user's
`%APPDATA%\Glide` (settings, keys, enrollment) is left behind; delete it if needed, and revoke the
devices in the console.
