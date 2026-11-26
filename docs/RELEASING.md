# Releasing Glide

How a release is built, signed and published, and what the maintainer has to set up once for
signed builds. The day-to-day steps (version bump, changelog, tag) are in
[CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-releases); IT administrators deploying a release
want [DEPLOYMENT.md](DEPLOYMENT.md).

## What the release workflow does

Pushing a tag `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml):

| Job | Runner | Produces |
|---|---|---|
| `check` | Ubuntu | tag = `VERSION`, tag on `main`, changelog entry, test vectors |
| `mac` | macOS | `Glide-Host-X.Y.Z-macos-arm64.{zip,dmg,pkg}`, `Glide-Viewer-X.Y.Z-macos-arm64.{zip,pkg}`: apps signed with the Developer ID Application certificate (hardened runtime, secure timestamp), pkgs signed with the Developer ID Installer certificate, apps, DMG and pkgs notarized and stapled |
| `windows-build` | Ubuntu | `glide-client.exe`, `glide-host.exe` (cargo test, MinGW cross-build) |
| `windows` | Windows | both exes signed with Azure Artifact Signing, `Glide-Viewer-X.Y.Z-windows-x64.zip`, `Glide-X.Y.Z-windows-x64.msi` (signed) |
| `publish` | Ubuntu | `SHA256SUMS`, the Homebrew cask, release notes, build provenance attestation, a **draft** GitHub Release |

Every signing step is skipped when its secrets are missing, so the same workflow builds a working
release without any of them: the Mac apps are then signed ad hoc (or with the self-signed
fallback certificate, below), the pkgs and the Windows files are unsigned, and the release notes
say so. Secrets are only handed to tag pushes; manual runs and pull requests that touch the release
tooling always build unsigned, so a branch's scripts never run with a signing key. Within a job a
secret is visible only to the step that uses it (the certificate imports, the notarization steps,
the signing action's inputs); the other steps see a true/false flag. The build steps can still use
the imported certificates through the temporary keychain, since they sign the apps, but never see a
`.p12` password, the API key or the Azure client secret.

`tools/release.sh` runs the same steps locally (`tools/release.sh --help`), and
`tools/notarize.sh` notarizes and staples with the same API key.

## The Windows MSI

`packaging/windows/build-msi.ps1` builds `Glide-X.Y.Z-windows-x64.msi` from
`packaging/windows/wix/Glide.wxs` with the WiX Toolset v5 .NET tool (version pinned in the
script, with the matching firewall extension). Both packages are pinned by content as well: the
script downloads them from nuget.org, checks their SHA-512 against
`packaging/windows/wix/packages.sha512` (the hashes nuget.org's catalog lists), installs the tool
from that local folder only, and loads the extension DLL from its verified package. To update WiX,
change the version in the script and record the new hashes after checking them against the
catalog (`packageHash`, base64 SHA-512). It needs Windows and the .NET SDK, so the release
workflow runs it in the `windows` job, after the exes are signed (the MSI embeds them) and before
the MSI itself is signed. Locally, on a Windows PC: `tools/release.sh viewer-build` in Git Bash or
WSL, then `pwsh packaging/windows/build-msi.ps1`.

The `UpgradeCode` in `Glide.wxs` must never change: it is how every Glide MSI finds and replaces
an earlier one (`MajorUpgrade`), and how admins' detection rules recognize it. MSI versions are
numeric, so a pre-release suffix (`0.5.0-rc.1`) is dropped from the MSI's ProductVersion; the file
name keeps it.

## Secrets

Add them under the repository's **Settings → Secrets and variables → Actions → Repository
secrets** (or an environment's secrets if you add a protected environment to the jobs). Each
platform's group is independent: set all of a group or none of it.

### macOS: Developer ID signing and notarization

| Secret | What | Used by |
|---|---|---|
| `MACOS_CERT_P12` | base64 of a `.p12` holding the **Developer ID Application** certificate and its private key | imported into a temporary keychain; `tools/mac-sign.sh` signs Glide Host.app (and the `glide-viewer` inside it) and Glide Viewer.app with `--options runtime --timestamp`; `tools/release.sh dmg` signs the DMG |
| `MACOS_CERT_PASSWORD` | the `.p12`'s export password | `security import` |
| `MACOS_INSTALLER_P12` | base64 of a `.p12` holding the **Developer ID Installer** certificate and its private key | same keychain; `tools/release.sh pkg` signs both pkgs (`productbuild --sign`) |
| `MACOS_INSTALLER_PASSWORD` | its export password | `security import` |
| `APPLE_API_KEY_P8` | the App Store Connect API key: the full text of the downloaded `AuthKey_XXXXXXXXXX.p8` | `tools/notarize.sh` writes it to a 0600 temporary file for `xcrun notarytool submit --wait`, then staples |
| `APPLE_API_KEY_ID` | the key's Key ID (10 characters) | `notarytool --key-id` |
| `APPLE_API_ISSUER` | the Issuer ID shown above the keys list (a UUID) | `notarytool --issuer` |

Optional, only used when `MACOS_CERT_P12` is absent:

| Secret | What |
|---|---|
| `MACOS_SELF_SIGN_P12`, `MACOS_SELF_SIGN_P12_PASSWORD` | the project's self-signed "Glide Release Signing" certificate. It gives every release the same designated requirement, so macOS keeps the privacy grants across updates, but Gatekeeper still blocks the first launch and MDMs can't target it reliably. Superseded by the Developer ID; keep it only until that is in place |

Notarization runs only with a Developer ID (Apple rejects anything else) and the pkgs are only
notarized when they are signed. Without the Installer certificate the pkgs are still built,
unsigned; MDMs such as Intune and Jamf need a signed pkg.

### Windows: Azure Artifact Signing

| Secret | What | Used by |
|---|---|---|
| `AZURE_TENANT_ID` | the Microsoft Entra tenant (directory) ID | `Azure/artifact-signing-action` (`azure-tenant-id`) |
| `AZURE_CLIENT_ID` | the app registration's application (client) ID | `azure-client-id` |
| `AZURE_CLIENT_SECRET` | a client secret of that app registration | `azure-client-secret` |
| `AZURE_SIGNING_ENDPOINT` | the signing account's regional endpoint, e.g. `https://eus.codesigning.azure.net/` | `endpoint` |
| `AZURE_SIGNING_ACCOUNT` | the Artifact Signing account name | `signing-account-name` |
| `AZURE_CERT_PROFILE` | the certificate profile name | `certificate-profile-name` |

The action (pinned to v2.0.0, commit `c7ab2a8`) signs `glide-client.exe` and `glide-host.exe`
before they are zipped and packed into the MSI, then the MSI itself; SHA-256 file digest, RFC 3161
timestamp from `http://timestamp.acs.microsoft.com`. Its dependency cache is turned off, like
every cache in the release workflow.

## Getting the certificates and keys

### Apple (macOS)

You need a paid **Apple Developer Program** membership (USD 99 a year; an organization enrolment
needs a D-U-N-S number and shows the organization's name on the certificates, an individual one
shows the person's name). Only the **Account Holder** can create Developer ID certificates.

1. **Developer ID Application.** On a Mac, Keychain Access → Certificate Assistant → *Request a
   Certificate From a Certificate Authority* (saved to disk). At
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates)
   → **+** → *Developer ID* → **Developer ID Application** (G2 Sub-CA), upload the request,
   download the certificate and double-click it. In Keychain Access → *My Certificates*, select
   "Developer ID Application: NAME (TEAMID)" together with its private key, *Export 2 items…* as
   `.p12` with a strong password. Then:

   ```sh
   base64 -i DeveloperIDApplication.p12 | pbcopy   # paste as MACOS_CERT_P12
   ```

   The team ID in parentheses is what the PPPC profile's code requirement names
   (`tools/fill-mdm-profiles.sh` reads it from a signed app).
2. **Developer ID Installer.** The same, choosing **Developer ID Installer**. Export it as a second
   `.p12` → `MACOS_INSTALLER_P12`, `MACOS_INSTALLER_PASSWORD`.
3. **App Store Connect API key.** At [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
   → *Users and Access* → *Integrations* → *App Store Connect API* → *Team Keys* → **+**, name it
   (e.g. "Glide notarization"), access **Developer**. Download the `.p8` (only possible once) and
   paste its whole text as `APPLE_API_KEY_P8`; copy the **Key ID** (`APPLE_API_KEY_ID`) and the
   **Issuer ID** at the top of the page (`APPLE_API_ISSUER`). Check it locally:

   ```sh
   xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

Developer ID certificates last five years; signed and timestamped releases stay valid after they
expire. Keep the `.p12` files and the `.p8` offline (a password manager), and delete the copies
you base64-encoded. If a key leaks, revoke the certificate at developer.apple.com and the API key
in App Store Connect, then replace the secrets.

### Microsoft Azure (Windows)

Azure Artifact Signing (formerly Trusted Signing) issues short-lived certificates from Microsoft's
CA and signs through an API, so there is no certificate file or hardware token to keep. It needs
an Azure subscription; the Basic tier costs about USD 10 a month (5,000 signatures). Public-trust
identity validation is available to organizations with a verifiable history and to individual
developers in supported countries (see Microsoft's current eligibility list).

1. **Signing account.** In the Azure portal, create an *Artifact Signing account* in a resource
   group, in the region closest to you; note its name (`AZURE_SIGNING_ACCOUNT`) and its
   **Account URI**, e.g. `https://eus.codesigning.azure.net/` (`AZURE_SIGNING_ENDPOINT`; the
   region must match the account).
2. **Identity validation.** Assign yourself the *Artifact Signing Identity Verifier* role on the
   account, then *Identity validation* → **New identity** → *Public*, as an organization or an
   individual. Microsoft checks the documents (often a few business days); the validated name is
   the publisher Windows shows.
3. **Certificate profile.** *Certificate profiles* → **Create** → *Public Trust*, pick the
   validated identity, name it (`AZURE_CERT_PROFILE`).
4. **App registration.** In Microsoft Entra ID → *App registrations* → **New registration**
   ("glide-release-signing", single tenant, no redirect URI). Note the **Directory (tenant) ID**
   (`AZURE_TENANT_ID`) and **Application (client) ID** (`AZURE_CLIENT_ID`). *Certificates &
   secrets* → **New client secret**; copy its **Value** (`AZURE_CLIENT_SECRET`) and put a
   reminder in your calendar before it expires (24 months at most).
5. **Role.** On the certificate profile (or the signing account) → *Access control (IAM)* →
   **Add role assignment** → **Artifact Signing Certificate Profile Signer** → assign it to the
   app registration. Nothing else needs access.

SmartScreen reputation follows the validated identity, so the first signed releases may still show
a warning for a short while until downloads build it up.

## Migrating from the old secret names

Releases up to 0.4.x used an Apple ID and an app-specific password to notarize, and passed the
identity name explicitly. The workflow no longer reads these; delete them once the new ones are in
place:

| Old secret | Replace with |
|---|---|
| `MACOS_SIGN_P12` | `MACOS_CERT_P12` (same content: base64 of the Developer ID Application `.p12`) |
| `MACOS_SIGN_P12_PASSWORD` | `MACOS_CERT_PASSWORD` |
| `MACOS_SIGN_ID` | nothing: the identity is read from the certificate |
| `MACOS_NOTARY_APPLE_ID` | `APPLE_API_KEY_P8` + `APPLE_API_KEY_ID` + `APPLE_API_ISSUER` (an App Store Connect API key instead of an Apple ID) |
| `MACOS_NOTARY_TEAM_ID` | nothing: the API key belongs to the team |
| `MACOS_NOTARY_PASSWORD` | nothing: revoke the app-specific password at account.apple.com |
| (none) | `MACOS_INSTALLER_P12`, `MACOS_INSTALLER_PASSWORD`: new, for the pkgs |
| (none) | `AZURE_*`: new, Windows signing |

`MACOS_SELF_SIGN_P12` and `MACOS_SELF_SIGN_P12_PASSWORD` keep their names and meaning.

```sh
gh secret set MACOS_CERT_P12 < <(base64 -i DeveloperIDApplication.p12)
gh secret set APPLE_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh secret delete MACOS_SIGN_P12   # and the other old names
```

**The bundle id changed too.** From the next release the apps are `dev.brandino.glide.host` and
`dev.brandino.glide.viewer` (up to 0.4.x: `io.github.sudobrandino.glide.host`). `install.sh`
and the pkg's postinstall move the LaunchAgent to the new label; macOS asks for Screen Recording
and Accessibility once more, because the grants belong to the old identifier.

## Checking a release

Before publishing the draft:

```sh
shasum -a 256 -c SHA256SUMS
spctl -a -vv -t exec "Glide Host.app"          # accepted, source=Notarized Developer ID
xcrun stapler validate Glide-Host-X.Y.Z-macos-arm64.dmg
pkgutil --check-signature Glide-Host-X.Y.Z-macos-arm64.pkg
spctl -a -vv -t install Glide-Host-X.Y.Z-macos-arm64.pkg
gh attestation verify Glide-Host-X.Y.Z-macos-arm64.pkg --repo sudoBrandino/glide
```

```powershell
Get-AuthenticodeSignature .\glide-client.exe, .\glide-host.exe, .\Glide-X.Y.Z-windows-x64.msi |
  Format-Table Status, SignerCertificate -AutoSize
```

Then generate the PPPC profile's code requirement from the signed host app with
`tools/fill-mdm-profiles.sh` (see [packaging/mdm/README.md](../packaging/mdm/README.md)); it
stays the same from release to release as long as the team ID does.
