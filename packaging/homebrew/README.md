# Homebrew cask

Testers can install the Mac host with Homebrew:

```sh
brew install --cask sudobrandino/glide/glide-host
glide-setup        # start at login, permissions, connection, pairing
```

The cask lives in a separate tap repository, `sudoBrandino/homebrew-glide`, as
`Casks/glide-host.rb`. This folder holds its template, `glide-host.rb.in`.

## How a release reaches the tap

1. `tools/release.sh cask` (run by the release workflow after `sums`) fills the template with the
   version and the SHA-256 of the host zip, and writes `glide-host.rb`. The workflow attaches it
   to the draft release.
2. When the release is published, `.github/workflows/homebrew-tap.yml` copies that file into the
   tap. It needs the repository secret `HOMEBREW_TAP_TOKEN`: a fine-grained token with
   **Contents: read and write** on `sudoBrandino/homebrew-glide` only. Without the secret, copy the
   file by hand.

## Setting up the tap (once)

```sh
gh repo create sudoBrandino/homebrew-glide --public --description "Homebrew tap for Glide" \
  --add-readme
```

Then add the `HOMEBREW_TAP_TOKEN` secret to this repository. The next published release fills
in `Casks/glide-host.rb`; to fill it in for an existing release, run the *Homebrew tap* workflow
by hand with that release's tag.

The cask needs a release whose app contains `Contents/Resources/glide-setup` (the first release
after 0.2.0): `binary` links it, and Homebrew refuses the install if it's missing. 0.2.0 has no
cask.

## What the cask does

- Installs `Glide Host.app` to `/Applications` and links `glide-setup` and `glide-host` into
  Homebrew's `bin`.
- Removes the quarantine flag (needed for releases built without the project's Developer ID,
  which are signed ad hoc and not notarized; harmless for notarized ones).
- Leaves the LaunchAgent to `glide-setup`: cask steps run in Homebrew's sandbox (with a
  temporary `$HOME`), where they can't install or start a per-user agent.
- `uninstall launchctl` stops the host and removes the agent (under the current bundle id,
  `dev.brandino.glide.host`, and the one releases up to 0.4.x used), on `brew uninstall` and also
  on `brew upgrade` (Homebrew skips only `signal` directives on upgrades). So the caveat asks for
  `glide-setup` after every upgrade: it restarts the host and, for ad-hoc-signed builds (each new
  build needs its Screen Recording and Accessibility grants again), re-requests the grants.
  `brew uninstall --zap` also removes the settings, the pairings and the log.
- Organizations deploying with an MDM use the `.pkg` instead (see
  [`docs/DEPLOYMENT.md`](../../docs/DEPLOYMENT.md)); `glide-setup` leaves a `.pkg` install alone.

## Checking a change to the template

```sh
GLIDE_RELEASE_OUT=/tmp/glide-cask tools/release.sh sums     # needs the zips there, or copy a SHA256SUMS in
GLIDE_RELEASE_OUT=/tmp/glide-cask tools/release.sh cask
brew tap-new --no-git glidetest/local && brew trust --tap glidetest/local
cp /tmp/glide-cask/glide-host.rb "$(brew --repository)/Library/Taps/glidetest/homebrew-local/Casks/"
brew style --cask glidetest/local/glide-host
brew untap glidetest/local && brew untrust --tap glidetest/local
```
