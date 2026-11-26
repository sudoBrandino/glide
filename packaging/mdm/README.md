# Glide MDM profiles (macOS)

Configuration profile templates for deploying Glide Host and Glide Viewer to managed Macs. The
full walkthrough, including the Windows side, is in [docs/DEPLOYMENT.md](../../docs/DEPLOYMENT.md);
this page covers the files and how each MDM takes them.

| File | Payload | Purpose |
|---|---|---|
| `glide-pppc.mobileconfig` | `com.apple.TCC.configuration-profile-policy` | Glide Host may use **Accessibility** (remote keyboard and mouse); **Screen Recording** set to `AllowStandardUserToSetSystemService`, so a standard user can switch it on (Apple doesn't let an MDM grant screen recording) |
| `glide-managed-preferences.mobileconfig` | `dev.brandino.glide` | `CloudURL`, `EnrollmentToken`, `DeviceName`, `Tags`, `DisableLANMode` ([ENTERPRISE.md §11.1](../../docs/ENTERPRISE.md#111-macos)); both apps read them |
| `dev.brandino.glide.plist` | (plain preferences) | the same keys without the profile wrapper, for MDMs that build the profile themselves |
| `glide-login-items.mobileconfig` | `com.apple.servicemanagement` | marks the host's LaunchAgent (label `dev.brandino.glide.host`) as a managed login item, so users can't switch it off and get no "background item added" notice |

The installers are the release's `Glide-Host-<version>-macos-<arch>.pkg` and
`Glide-Viewer-<version>-macos-<arch>.pkg`: signed with Glide's Developer ID Installer certificate,
notarized, installing to `/Applications` for all users. The host pkg also installs
`/Library/LaunchAgents/dev.brandino.glide.host.plist` and starts the host for whoever is logged in.

## 1. Fill in the templates

The PPPC profile has to name the app's code requirement, which ties it to the bundle id and to
the Developer ID team that signs Glide. Generate the profiles from the release you deploy:

```sh
tools/fill-mdm-profiles.sh \
  --cloud-url https://glide.example.com --token "<enrollment token>" \
  --org "Example Corp" \
  Glide-Host-<version>-macos-arm64.pkg  out/
```

It reads the requirement with `codesign -dr -` (refusing anything not signed with a Developer
ID), replaces the `TEAMID` placeholder, gives every payload a fresh `PayloadUUID`, fills in the
managed preferences, and checks each file with `plutil -lint`. Options: `--device-name`, `--tag`
(repeatable), `--disable-lan`; `--help` lists them. The requirement stays the same across releases
as long as the team does, so this is needed once, not per release.

The filled-in preferences contain the enrollment token: keep them out of source control, and give
the token an expiry or a maximum number of uses in the admin console.

Upload order matters little, but deploy the PPPC and login-items profiles **before** (or together
with) the pkg, so the host finds its permissions in place when it first starts.

## 2. Jamf Pro

1. **Packages:** Settings → Computer management → Packages → upload both `.pkg` files.
2. **Policy:** Computers → Policies → New: *Packages* → add them (Install); trigger *Enrollment
   Complete* and *Recurring Check-in*, frequency *Once per computer*; scope to your target group.
3. **PPPC:** Computers → Configuration Profiles → **Upload** `glide-pppc.mobileconfig` (Jamf keeps
   the payload as is; alternatively build it in the *Privacy Preferences Policy Control* payload
   with the identifier and code requirement the script printed).
4. **Managed login items:** upload `glide-login-items.mobileconfig` (or the *Managed Login Items*
   payload: rule type *Label*, value `dev.brandino.glide.host`).
5. **Settings:** either upload `glide-managed-preferences.mobileconfig`, or a new profile →
   *Application & Custom Settings* → *Upload* → preference domain `dev.brandino.glide`, with
   `dev.brandino.glide.plist`. Jamf substitutes variables in custom settings, so
   `<string>$COMPUTERNAME</string>` works for `DeviceName`.
6. Scope all three profiles to the same group as the policy.

## 3. Microsoft Intune

1. **App:** Apps → macOS → Add → *macOS app (PKG)* → upload `Glide-Host-…pkg` (repeat for the
   viewer). Intune requires a signed pkg. Detection: the app bundle id `dev.brandino.glide.host`
   (resp. `dev.brandino.glide.viewer`) with the release version; *Ignore app version* if you
   update by uploading new pkgs. Assign as *Required*.
2. **PPPC and login items:** Devices → Configuration → Create → macOS → *Templates* → **Custom**
   → upload `glide-pppc.mobileconfig` (deployment channel: *Device channel*). Repeat for
   `glide-login-items.mobileconfig`. (The Settings catalog also has *Privacy Preferences Policy
   Control* and *Login Items*; use the identifier and code requirement the script printed.)
3. **Settings:** Devices → Configuration → Create → macOS → *Templates* → **Preference file** →
   preference domain `dev.brandino.glide`, upload `dev.brandino.glide.plist` (leave `DeviceName`
   empty: Intune doesn't substitute variables there). Or upload
   `glide-managed-preferences.mobileconfig` as a Custom profile.
4. Assign the profiles to the same group as the app.

## 4. Kandji

1. **Custom App:** Library → Add new → *Custom App* → upload the pkg, installation type
   *Installer package*, *Install once per device*; assign to your Blueprint. Repeat for the viewer.
2. **PPPC:** Library → Add new → *Privacy* (PPPC) → app identifier `dev.brandino.glide.host`,
   type *Bundle ID*, code requirement from the script; Accessibility *Allow*, Screen Capture
   *Allow standard users to approve*. Or Library → *Custom Profile* → upload
   `glide-pppc.mobileconfig`.
3. **Login items:** Library → *Custom Profile* → upload `glide-login-items.mobileconfig` (or the
   *Login & Background Items* library item: managed login item, label `dev.brandino.glide.host`).
4. **Settings:** Library → *Custom Profile* → upload `glide-managed-preferences.mobileconfig`.
   Kandji substitutes global variables in custom profiles, so `$DEVICE_NAME` works for
   `DeviceName`.

## 5. Check a Mac

```sh
sudo profiles show -type configuration | grep -A3 dev.brandino.glide   # the three profiles
defaults read "/Library/Managed Preferences/dev.brandino.glide"         # the managed settings
launchctl print "gui/$(id -u)/dev.brandino.glide.host" | head -20        # the host is running
sfltool dumpbtm | grep -B2 -A8 dev.brandino.glide.host                  # login item, "managed"
```

Once enrolled, the host's menu bar menu says "Managed by <organization>" and the device
then appears in the Glide Cloud console. Screen Recording still needs one click by the user:
the host's setup window opens System Settings at the right place.

Removing Glide: `sudo "/Applications/Glide Host.app/Contents/Resources/glide-uninstall"`
(`--purge` also removes settings, keys and enrollment), then remove the profiles in the MDM.
