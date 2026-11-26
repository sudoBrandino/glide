#!/bin/bash
# Builds a Glide release locally, without CI: the same steps .github/workflows/release.yml runs.
#
#   tools/release.sh                 everything below, into dist/release/<version>/
#   tools/release.sh host            Glide-Host-<ver>-macos-<arch>.zip   (macOS only)
#   tools/release.sh mac-viewer      Glide-Viewer-<ver>-macos-<arch>.zip (macOS only; Glide Viewer.app)
#   tools/release.sh dmg             Glide-Host-<ver>-macos-<arch>.dmg from that zip (macOS only;
#                                    after notarizing, so the DMG holds the stapled app)
#   tools/release.sh pkg             Glide-{Host,Viewer}-<ver>-macos-<arch>.pkg from the zips:
#                                    installers for MDM (macOS only; after notarizing the zips)
#   tools/release.sh viewer          Glide-Viewer-<ver>-windows-x64.zip  (macOS or Linux, MinGW-w64):
#                                    viewer-build, then viewer-zip
#   tools/release.sh viewer-build    cargo test + cross-build; glide-client.exe and glide-host.exe
#                                    into <out>/windows/ (the release workflow signs them there)
#   tools/release.sh viewer-zip      the viewer zip from <out>/windows/ (needs zip or 7z)
#   tools/release.sh notes           RELEASE_NOTES.md from CHANGELOG.md
#   tools/release.sh sums            SHA256SUMS over the zips, DMGs, pkgs and MSI in the output folder
#   tools/release.sh cask            glide-host.rb, the Homebrew cask, from SHA256SUMS
#                                    (packaging/homebrew/README.md)
#   tools/release.sh check           version consistency + CHANGELOG entry, nothing is built
#
# Options (environment):
#   GLIDE_RELEASE_OUT=DIR     output folder (default: dist/release/<version>)
#   GLIDE_SKIP_TESTS=1        skip glide-selftest and cargo test before packaging
#   GLIDE_HOST_ARCHS="arm64 x86_64"  universal host binary (default: arm64 only; see docs/INSTALL.md)
#   GLIDE_SIGN_ID, GLIDE_BUNDLE_ID, GLIDE_VIEWER_BUNDLE_ID, GLIDE_HARDENED_RUNTIME,
#   GLIDE_SIGN_KEYCHAIN: see tools/mac-sign.sh and tools/build-env.sh (.dev/build.env is read)
#   GLIDE_INSTALLER_SIGN_ID   "Developer ID Installer: …" identity for the .pkg (default: unsigned)
#   GLIDE_MAC_NOTARIZED=1, GLIDE_WINDOWS_SIGNED=1   notes: say the downloads are notarized / signed
#                             (the release workflow sets them; docs/RELEASING.md)
# The version is the VERSION file (tools/version.sh). Nothing is uploaded or tagged.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
# shellcheck source=tools/mac-sign.sh
source "$ROOT/tools/mac-sign.sh"
VERSION="$("$ROOT/tools/version.sh")"
OUT="${GLIDE_RELEASE_OUT:-$ROOT/dist/release/$VERSION}"
DEFAULT_BUNDLE_ID="dev.brandino.glide.host"
DEFAULT_VIEWER_BUNDLE_ID="dev.brandino.glide.viewer"
VIEWER_ZIP="Glide-Viewer-$VERSION-windows-x64.zip"
TARGET="x86_64-pc-windows-gnu"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }
trap 'echo "error: tools/release.sh failed (line $LINENO: $BASH_COMMAND)" >&2' ERR

# Commit recorded in both artifacts (Info.plist GlideCommit, glide-client --version).
if [[ -z "${GLIDE_BUILD_COMMIT:-}" ]]; then
  GLIDE_BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] || GLIDE_BUILD_COMMIT+="-dirty"
fi
export GLIDE_BUILD_COMMIT

# cargo on PATH, or the default rustup toolchain's (Homebrew's rustup doesn't link the proxies).
ensure_cargo() {
  command -v cargo >/dev/null && return
  command -v rustup >/dev/null || die "cargo not found (install Rust: https://rustup.rs)"
  PATH="$(dirname "$(rustup which cargo)"):$PATH"
  export PATH
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# The CHANGELOG.md section for a version, without its heading.
changelog_section() {
  awk -v v="$1" '
    $0 ~ "^## \\[" v "\\]" { on = 1; next }
    on && /^## \[/ { exit }
    on && /^\[[^]]+\]: / { next }   # link reference definitions at the end of the file
    on { print }
  ' "$ROOT/CHANGELOG.md" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

cmd_check() {
  "$ROOT/tools/version.sh" check
  [[ -n "$(changelog_section "$VERSION" | tr -d '[:space:]')" ]] \
    || die "CHANGELOG.md has no '## [$VERSION]' section with content"
  echo "CHANGELOG.md: [$VERSION] section present"
  # Releasing from a tag: everything under [Unreleased] must have been folded into [$VERSION],
  # or the release notes silently miss it.
  if [[ "${GITHUB_REF:-}" == refs/tags/* || "${GLIDE_RELEASE_STRICT:-0}" == 1 ]]; then
    [[ -z "$(changelog_section Unreleased | { grep -v '^###' || true; } | tr -d '[:space:]')" ]] \
      || die "CHANGELOG.md still has entries under [Unreleased]; fold them into [$VERSION] before tagging"
  fi
  if [[ "$GLIDE_BUILD_COMMIT" == *-dirty ]]; then
    echo "warning: the working tree has uncommitted changes; artifacts are stamped $GLIDE_BUILD_COMMIT" >&2
  fi
}

# A personal bundle id or development certificate (from .dev/build.env) would end up in a public
# download. Override on the command line, or opt in with GLIDE_RELEASE_CUSTOM_ID=1.
check_release_identity() {
  local var="$1" have="$2" want="$3"
  if [[ "$have" != "$want" && "${GLIDE_RELEASE_CUSTOM_ID:-0}" != 1 ]]; then
    die "$var is '$have' (from .dev/build.env?), not the public default
       '$want'. LaunchAgent labels, privacy grants and MDM profiles key on it. Run
       $var=$want GLIDE_SIGN_ID=- tools/release.sh, or set
       GLIDE_RELEASE_CUSTOM_ID=1 to build with it anyway."
  fi
  case "$GLIDE_SIGN_ID" in
    # "Glide Release Signing": the project's self-signed certificate (no personal details in it);
    # it keeps macOS privacy grants across releases. See docs/INSTALL.md "Signing".
    -|"Developer ID Application:"*|"Glide Release Signing") ;;
    *) [[ "${GLIDE_RELEASE_CUSTOM_ID:-0}" == 1 ]] || die "GLIDE_SIGN_ID is '$GLIDE_SIGN_ID' (from .dev/build.env?). Public releases
       are signed ad hoc (GLIDE_SIGN_ID=-) or with a Developer ID; a development certificate embeds
       its name (often an email address) in the app. Set GLIDE_RELEASE_CUSTOM_ID=1 to use it anyway."
       echo "warning: signing with '$GLIDE_SIGN_ID' (GLIDE_RELEASE_CUSTOM_ID=1)" >&2 ;;
  esac
}

# arm64 / x86_64 / universal, from a binary's architectures.
arch_name() {
  local archs; archs="$(lipo -archs "$1")"
  case "$archs" in
    arm64) echo arm64 ;;
    x86_64) echo x86_64 ;;
    *arm64*x86_64*|*x86_64*arm64*) echo universal ;;
    *) die "unexpected architectures in $1: $archs" ;;
  esac
}

cmd_host() {
  [[ "$(uname -s)" == Darwin ]] || die "the host app can only be built on macOS"
  check_release_identity GLIDE_BUNDLE_ID "$GLIDE_BUNDLE_ID" "$DEFAULT_BUNDLE_ID"
  mkdir -p "$OUT"
  if [[ "${GLIDE_SKIP_TESTS:-0}" != 1 ]]; then
    say "host: release build + selftest"
    (cd "$ROOT/mac" && swift build -c release --build-system native >/dev/null)
    "$ROOT/mac/.build/release/glide-selftest" "$ROOT/docs/test-vectors.json" | tail -1
  fi
  local stage; stage="$(mktemp -d)"
  say "host: Glide Host.app (sign id: $GLIDE_SIGN_ID, bundle id: $GLIDE_BUNDLE_ID)"
  GLIDE_APP_OUT="$stage/Glide Host.app" "$ROOT/tools/make-host-app.sh"
  local app="$stage/Glide Host.app" bin arch_name
  bin="$app/Contents/MacOS/glide-host"
  arch_name="$(arch_name "$bin")"
  local got; got="$("$bin" --version)"
  [[ "$got" == "glide-host $VERSION ("*")"* ]] || die "glide-host --version says '$got', expected $VERSION"
  echo "$got"
  [[ -x "$app/Contents/MacOS/glide-viewer" ]] || die "Glide Host.app holds no glide-viewer"
  [[ "$(lipo -archs "$app/Contents/MacOS/glide-viewer")" == "$(lipo -archs "$bin")" ]] \
    || die "glide-viewer is built for $(lipo -archs "$app/Contents/MacOS/glide-viewer"), glide-host for $(lipo -archs "$bin")"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$VERSION" ]] \
    || die "Info.plist CFBundleShortVersionString != $VERSION"
  local zip="$OUT/Glide-Host-$VERSION-macos-$arch_name.zip"
  rm -f "$OUT"/Glide-Host-"$VERSION"-macos-*.zip
  # ditto keeps the bundle's symlinks, extended attributes and code signature intact.
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  rm -rf "$stage"
  echo "wrote $zip"
}

cmd_mac_viewer() {
  [[ "$(uname -s)" == Darwin ]] || die "the Mac viewer app can only be built on macOS"
  check_release_identity GLIDE_VIEWER_BUNDLE_ID "$GLIDE_VIEWER_BUNDLE_ID" "$DEFAULT_VIEWER_BUNDLE_ID"
  mkdir -p "$OUT"
  local stage; stage="$(mktemp -d)"
  say "mac viewer: Glide Viewer.app (sign id: $GLIDE_SIGN_ID, bundle id: $GLIDE_VIEWER_BUNDLE_ID)"
  GLIDE_VIEWER_APP_OUT="$stage/Glide Viewer.app" "$ROOT/tools/make-viewer-app.sh"
  local app="$stage/Glide Viewer.app" arch
  arch="$(arch_name "$app/Contents/MacOS/glide-viewer")"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$VERSION" ]] \
    || die "Info.plist CFBundleShortVersionString != $VERSION"
  local zip="$OUT/Glide-Viewer-$VERSION-macos-$arch.zip"
  rm -f "$OUT"/Glide-Viewer-"$VERSION"-macos-*.zip
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  rm -rf "$stage"
  echo "wrote $zip"
}

# Installer packages for MDM (docs/DEPLOYMENT.md), from the (notarized, stapled) zips: one per app,
# installed to /Applications for all users. The host's also installs the system-wide LaunchAgent
# (packaging/macos/dev.brandino.glide.host.plist) and a postinstall that starts it for whoever is
# logged in and removes per-user agents (packaging/macos/scripts/host/postinstall). Signed with
# GLIDE_INSTALLER_SIGN_ID ("Developer ID Installer: …") when set.
cmd_pkg() {
  [[ "$(uname -s)" == Darwin ]] || die "pkg needs macOS (pkgbuild, productbuild)"
  local zip="" found=0
  for zip in "$OUT"/Glide-Host-"$VERSION"-macos-*.zip "$OUT"/Glide-Viewer-"$VERSION"-macos-*.zip; do
    [[ -e "$zip" ]] || continue
    build_pkg "$zip"
    found=1
  done
  [[ $found == 1 ]] || die "no Glide-{Host,Viewer}-$VERSION-macos-*.zip in $OUT (run: tools/release.sh host mac-viewer)"
}

build_pkg() {
  local zip="$1" kind="" arch="" archs="" stage="" root="" app="" id="" pkg="" label=""
  case "$(basename "$zip")" in
    Glide-Host-*) kind=Host ;;
    Glide-Viewer-*) kind=Viewer ;;
  esac
  arch="${zip##*-macos-}"; arch="${arch%.zip}"
  case "$arch" in
    arm64) archs=arm64 ;;
    x86_64) archs=x86_64 ;;
    universal) archs="arm64,x86_64" ;;
    *) die "unexpected architecture in $zip" ;;
  esac
  stage="$(mktemp -d)"; root="$stage/root"
  mkdir -p "$root/Applications" "$stage/pkgs"
  ditto -x -k "$zip" "$root/Applications"
  app="$root/Applications/Glide $kind.app"
  [[ -d "$app" ]] || die "$zip holds no Glide $kind.app"
  codesign --verify --strict "$app" || die "Glide $kind.app in $zip has a broken signature"
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  local scripts=()
  # No extended attributes (quarantine, Finder info) in the payload: pkgbuild ships them as ._
  # AppleDouble entries. The signature and a stapled ticket live in files, not xattrs. (A developer
  # Mac re-attaches com.apple.provenance, which can't be cleared; CI runners don't set it.)
  xattr -cr "$root"
  codesign --verify --strict "$app" || die "Glide $kind.app lost its signature without xattrs"
  if [[ $kind == Host ]]; then
    # The packaging files name the public bundle id; a custom one (GLIDE_RELEASE_CUSTOM_ID) is
    # substituted so the agent label, the postinstall and the app agree.
    label="$id"
    mkdir -p "$root/Library/LaunchAgents" "$stage/scripts"
    sed "s/dev\.brandino\.glide\.host/$label/g" "$ROOT/packaging/macos/dev.brandino.glide.host.plist" \
      > "$root/Library/LaunchAgents/$label.plist"
    chmod 0644 "$root/Library/LaunchAgents/$label.plist"
    plutil -lint -s "$root/Library/LaunchAgents/$label.plist" || die "bad LaunchAgent plist"
    sed "s/^LABEL=\"dev\.brandino\.glide\.host\"$/LABEL=\"$label\"/" "$ROOT/packaging/macos/scripts/host/postinstall" \
      > "$stage/scripts/postinstall"
    chmod 0755 "$stage/scripts/postinstall"
    scripts=(--scripts "$stage/scripts")
  fi
  # Never relocate: Installer would otherwise update a copy of the app it finds elsewhere (for
  # example ~/Applications) instead of installing to /Applications, where the LaunchAgent and
  # the MDM profiles expect it.
  pkgbuild --analyze --root "$root" "$stage/component.plist" >/dev/null
  local i=0
  while plutil -extract "$i" raw -o - "$stage/component.plist" >/dev/null 2>&1; do
    plutil -replace "$i.BundleIsRelocatable" -bool NO "$stage/component.plist"
    plutil -replace "$i.BundleOverwriteAction" -string upgrade "$stage/component.plist"
    i=$((i + 1))
  done
  pkgbuild --quiet --root "$root" --component-plist "$stage/component.plist" --install-location / \
    --identifier "$id.pkg" --version "$VERSION" ${scripts[@]+"${scripts[@]}"} "$stage/pkgs/component.pkg"
  sed -e "s/@TITLE@/Glide $kind $VERSION/" -e "s/@PKG_ID@/$id.pkg/g" -e "s/@VERSION@/$VERSION/" \
      -e "s/@ARCHS@/$archs/" "$ROOT/packaging/macos/distribution.xml.in" > "$stage/distribution.xml"
  pkg="$OUT/Glide-$kind-$VERSION-macos-$arch.pkg"
  rm -f "$pkg"
  local sign=()
  if [[ -n "${GLIDE_INSTALLER_SIGN_ID:-}" ]]; then
    sign=(--sign "$GLIDE_INSTALLER_SIGN_ID" --timestamp)
    [[ -n "${GLIDE_SIGN_KEYCHAIN:-}" ]] && sign+=(--keychain "$GLIDE_SIGN_KEYCHAIN")
  fi
  productbuild --quiet --distribution "$stage/distribution.xml" --package-path "$stage/pkgs" ${sign[@]+"${sign[@]}"} "$pkg"
  rm -rf "$stage"
  if [[ ${#sign[@]} -gt 0 ]]; then
    pkgutil --check-signature "$pkg" | sed -n '1,4p'
  else
    echo "note: $pkg is not signed (no GLIDE_INSTALLER_SIGN_ID); MDMs such as Intune require a signed pkg" >&2
  fi
  echo "wrote $pkg"
}

# The download most people use: open it, drag Glide Host to Applications, open it from there.
# The app's setup window does the rest (login item, permissions, connection, pairing).
cmd_dmg() {
  [[ "$(uname)" == Darwin ]] || die "dmg needs macOS (hdiutil)"
  local zip="" dmg="" stage=""
  for zip in "$OUT"/Glide-Host-"$VERSION"-macos-*.zip; do
    [[ -e "$zip" ]] || die "no Glide-Host-$VERSION-macos-*.zip in $OUT (run: tools/release.sh host)"
    dmg="${zip%.zip}.dmg"
    stage="$(mktemp -d)"
    ditto -x -k "$zip" "$stage"
    [[ -d "$stage/Glide Host.app" ]] || die "$zip holds no Glide Host.app"
    ln -s /Applications "$stage/Applications"
    rm -f "$dmg"
    hdiutil create -quiet -volname "Glide Host $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
    rm -rf "$stage"
    hdiutil verify -quiet "$dmg"
    # With a Developer ID the DMG is signed too, so it can be notarized and stapled itself.
    if [[ "$GLIDE_SIGN_ID" == "Developer ID Application:"* ]]; then
      local id="$GLIDE_SIGN_ID" kc=()
      if [[ -n "${GLIDE_SIGN_KEYCHAIN:-}" ]]; then
        id="$(glide_find_identity "$GLIDE_SIGN_KEYCHAIN" "$GLIDE_SIGN_ID")"
        kc=(--keychain "$GLIDE_SIGN_KEYCHAIN")
      fi
      codesign --force --timestamp --sign "$id" ${kc[@]+"${kc[@]}"} "$dmg"
    fi
    echo "wrote $dmg"
  done
}

cmd_viewer() {
  cmd_viewer_build
  cmd_viewer_zip
}

cmd_viewer_build() {
  mkdir -p "$OUT/windows"
  ensure_cargo
  if [[ "${GLIDE_SKIP_TESTS:-0}" != 1 ]]; then
    say "viewer: cargo test"
    local log; log="$(mktemp)"
    if ! (cd "$ROOT/windows" && cargo test --locked) >"$log" 2>&1; then
      tail -60 "$log"; rm -f "$log"; die "cargo test failed"
    fi
    grep -E '^test result' "$log"; rm -f "$log"
  fi
  say "viewer: cross-build $TARGET"
  (cd "$ROOT/windows" && cargo build --locked --release --target "$TARGET")
  local exe=""
  for exe in glide-client.exe glide-host.exe; do
    [[ -f "$ROOT/windows/target/$TARGET/release/$exe" ]] || die "build produced no $exe"
    # Static CRT (+crt-static in windows/.cargo/config.toml): no MinGW runtime DLLs allowed.
    if command -v x86_64-w64-mingw32-objdump >/dev/null; then
      if x86_64-w64-mingw32-objdump -p "$ROOT/windows/target/$TARGET/release/$exe" | grep -iE 'DLL Name: (libgcc|libwinpthread|libstdc)'; then
        die "$exe links MinGW runtime DLLs"
      fi
    fi
    cp "$ROOT/windows/target/$TARGET/release/$exe" "$OUT/windows/$exe"
  done
  echo "wrote $OUT/windows/glide-client.exe, glide-host.exe"
}

# The viewer zip, from the exes in <out>/windows/ (signed by then in the release workflow).
cmd_viewer_zip() {
  local exe=""
  for exe in glide-client.exe glide-host.exe; do
    [[ -f "$OUT/windows/$exe" ]] || die "no $OUT/windows/$exe (run: tools/release.sh viewer-build)"
  done
  local stage; stage="$(mktemp -d)"
  cp "$OUT/windows/glide-client.exe" "$stage/glide-client.exe"
  # The Windows host (a Mac controls this PC, docs/WINDOWS_HOST.md), in the same zip.
  cp "$OUT/windows/glide-host.exe" "$stage/glide-host.exe"
  # Text files for Notepad: CRLF line endings.
  sed 's/$/\r/' "$ROOT/LICENSE" > "$stage/LICENSE.txt"
  sed 's/$/\r/' > "$stage/README.txt" <<EOF
Glide viewer $VERSION (Windows 10/11 x64), protocol v2, commit $GLIDE_BUILD_COMMIT

Run glide-client.exe. The first time, its setup window offers to install it, asks for the
Mac's address, and whether the Mac may connect to this PC as well (with a Windows Firewall
rule). Either side can open the connection on TCP port 7420; one direction that your network
allows is enough. From a command line instead:

    glide-client.exe 192.168.1.50              dial the Mac; it may also connect to this PC
    glide-client.exe 192.168.1.50 --no-listen  dial only
    glide-client.exe --listen                  only wait for the Mac to connect

The first connection pairs this PC with the Mac: both screens show the same 6-digit code;
confirm on both only if they match. Settings: %APPDATA%\\Glide\\config.json.
Requires a GPU with HEVC hardware decode and the "HEVC Video Extensions" from the Microsoft Store.

To control this PC from a Mac instead (preview), run glide-host.exe here and glide-viewer on the
Mac (it comes with Glide Host). The PC listens on TCP port 7421; pair from its tray icon with
"Pair New Mac...". Guide: https://github.com/sudoBrandino/glide/blob/v$VERSION/docs/WINDOWS_HOST.md

Install guide (SmartScreen, firewall, pairing, troubleshooting):
https://github.com/sudoBrandino/glide/blob/v$VERSION/docs/INSTALL.md
All viewer options: glide-client.exe --help
EOF
  rm -f "$OUT/$VIEWER_ZIP"
  if command -v zip >/dev/null; then
    (cd "$stage" && zip -X -q "$OUT/$VIEWER_ZIP" glide-client.exe glide-host.exe README.txt LICENSE.txt)
  elif command -v 7z >/dev/null; then   # Windows runners (Git Bash) have 7-Zip, not zip
    (cd "$stage" && 7z a -tzip -bd -bso0 "$OUT/$VIEWER_ZIP" glide-client.exe glide-host.exe README.txt LICENSE.txt)
  else
    die "neither zip nor 7z is installed"
  fi
  rm -rf "$stage"
  echo "wrote $OUT/$VIEWER_ZIP"
}

cmd_notes() {
  mkdir -p "$OUT"
  local notes="$OUT/RELEASE_NOTES.md" body z desc
  local notarized="${GLIDE_MAC_NOTARIZED:-0}" signed="${GLIDE_WINDOWS_SIGNED:-0}"
  local blob="https://github.com/sudoBrandino/glide/blob/v$VERSION"
  # Relative links (docs/INSTALL.md) don't resolve on the release page: point them at the tag.
  body="$(changelog_section "$VERSION" | sed -E "s#\]\((docs/|[A-Z]+\.md)#]($blob/\1#g")"
  [[ -n "${body//[[:space:]]/}" ]] || die "CHANGELOG.md has no '## [$VERSION]' section"
  {
    echo "$body"
    echo
    echo "## Downloads"
    echo
    echo "| File | For |"
    echo "|---|---|"
    for z in "$OUT"/Glide-Host-"$VERSION"-macos-*.dmg "$OUT"/Glide-Host-"$VERSION"-macos-*.zip \
             "$OUT"/Glide-Host-"$VERSION"-macos-*.pkg "$OUT"/Glide-Viewer-"$VERSION"-macos-*.zip \
             "$OUT"/Glide-Viewer-"$VERSION"-macos-*.pkg; do
      [[ -e "$z" ]] || continue
      desc="macOS 14+ on Apple silicon"
      [[ "$z" == *-universal.* ]] && desc="macOS 14+, universal (Apple silicon; Intel untested, see the install guide)"
      case "$(basename "$z")" in
        Glide-Host-*.dmg) echo "| \`$(basename "$z")\` | **Mac host, start here:** open it, drag Glide Host to Applications, open it; its setup window does the rest. $desc |" ;;
        Glide-Host-*.zip) echo "| \`$(basename "$z")\` | Mac host as a zip (install script, Homebrew), $desc$([[ $notarized == 1 ]] || echo ". Not notarized") |" ;;
        Glide-Host-*.pkg) echo "| \`$(basename "$z")\` | Mac host installer for all users, for MDM (Jamf, Intune, Kandji): [deployment guide]($blob/docs/DEPLOYMENT.md). $desc |" ;;
        Glide-Viewer-*.zip) echo "| \`$(basename "$z")\` | Mac viewer for a Windows host (preview, [docs]($blob/docs/WINDOWS_HOST.md)), $desc |" ;;
        Glide-Viewer-*.pkg) echo "| \`$(basename "$z")\` | Mac viewer installer, for MDM, $desc |" ;;
      esac
    done
    echo "| \`$VIEWER_ZIP\` | Windows viewer \`glide-client.exe\`, and \`glide-host.exe\` to control this PC from a Mac (preview). Windows 10/11 x64 |"
    for z in "$OUT"/Glide-*-windows-x64.msi; do
      [[ -e "$z" ]] || continue
      echo "| \`$(basename "$z")\` | Windows installer for all users (viewer and host, Program Files), for Intune, SCCM or Group Policy: [deployment guide]($blob/docs/DEPLOYMENT.md) |"
    done
    echo "| \`SHA256SUMS\` | Checksums: \`shasum -a 256 -c SHA256SUMS\` (Mac) or \`Get-FileHash\` (Windows) |"
    echo
    echo "## Install"
    echo
    if [[ $notarized == 1 ]]; then
      echo "**Mac:** download the \`.dmg\`, drag **Glide Host** to Applications and open it. The app is"
      echo "signed with a Developer ID and notarized by Apple. The setup window walks through starting at"
      echo "login, the two permissions, the connection and pairing."
    else
      echo "**Mac:** download the \`.dmg\`, drag **Glide Host** to Applications and open it. The app is"
      echo "not notarized, so the first time macOS refuses to open it: go to System Settings → Privacy &"
      echo "Security and click **Open Anyway**. Then the setup window walks through starting at login,"
      echo "the two permissions, the connection and pairing."
    fi
    echo
    if [[ $signed == 1 ]]; then
      echo "**Windows:** download the viewer zip, run \`glide-client.exe\` (code-signed) and follow its setup window."
    else
      echo "**Windows:** download the viewer zip, run \`glide-client.exe\` and follow its setup window."
    fi
    echo
    echo "**Organizations:** the \`.pkg\` and \`.msi\` installers, configuration profiles and Group Policy"
    echo "templates are described in the [deployment guide]($blob/docs/DEPLOYMENT.md)."
    echo
    echo "**Controlling a PC from a Mac (preview):** run \`glide-host.exe\` from the same zip on the PC and"
    echo "\`glide-viewer\` on the Mac. It ships inside Glide Host: Homebrew puts it on PATH, otherwise run"
    echo "\`\"/Applications/Glide Host.app/Contents/MacOS/glide-viewer\"\`. See [WINDOWS_HOST.md](https://github.com/sudoBrandino/glide/blob/v$VERSION/docs/WINDOWS_HOST.md)."
    echo
    echo "From a terminal instead (same result): \`curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/v$VERSION/install.sh | bash\`,"
    echo "or \`brew install --cask sudobrandino/glide/glide-host\` (then \`glide-setup\`). Windows, in PowerShell:"
    echo
    echo '```powershell'
    echo "irm https://raw.githubusercontent.com/sudoBrandino/glide/v$VERSION/install.ps1 | iex"
    echo '```'
    echo
    echo "To install by hand, follow the [install guide]($blob/docs/INSTALL.md):"
    if [[ $notarized == 1 ]]; then
      echo "the host needs the Screen Recording and Accessibility permissions."
    else
      echo "the Mac app is not notarized, so macOS blocks it until you clear the quarantine flag, and"
      echo "the host needs the Screen Recording and Accessibility permissions."
    fi
  } > "$notes"
  echo "wrote $notes"
}

# The Homebrew cask for the Mac host, from packaging/homebrew/glide-host.rb.in and SHA256SUMS.
cmd_cask() {
  local zip="" sha="" arch="" depends=""
  [[ -f "$OUT/SHA256SUMS" ]] || die "no $OUT/SHA256SUMS (run: tools/release.sh sums)"
  for arch in arm64 universal; do
    zip="Glide-Host-$VERSION-macos-$arch.zip"
    sha="$(awk -v f="$zip" '$2 == f || $2 == "*" f { print $1; exit }' "$OUT/SHA256SUMS")"
    [[ -n "$sha" ]] && break
  done
  [[ -n "$sha" ]] || die "SHA256SUMS lists no Glide-Host-$VERSION-macos-{arm64,universal}.zip"
  [[ "$arch" == arm64 ]] && depends="depends_on arch: :arm64"
  # Swap the template's header comment for a "generated" note; drop @ARCH_DEPENDS@'s line when
  # the build is universal.
  awk -v ver="$VERSION" -v sha="$sha" -v arch="$arch" -v dep="$depends" '
    BEGIN { print "# Generated by tools/release.sh cask for Glide " ver ". Edit packaging/homebrew/glide-host.rb.in." }
    !body && /^#/ { next }
    { body = 1 }
    /@ARCH_DEPENDS@/ { if (dep == "") next; sub(/@ARCH_DEPENDS@/, dep) }
    { gsub(/@VERSION@/, ver); gsub(/@SHA256@/, sha); gsub(/@ARCH@/, arch); print }
  ' "$ROOT/packaging/homebrew/glide-host.rb.in" > "$OUT/glide-host.rb"
  echo "wrote $OUT/glide-host.rb ($zip)"
}

cmd_sums() {
  ( cd "$OUT"
    shopt -s nullglob
    zips=(Glide-*.zip Glide-*.dmg Glide-*.pkg Glide-*.msi)
    [[ ${#zips[@]} -gt 0 ]] || die "no Glide-*.zip in $OUT"
    sha256 "${zips[@]}" > SHA256SUMS
    cat SHA256SUMS )
}

case "${1:-all}" in
  check) cmd_check ;;
  host) cmd_host ;;
  mac-viewer) cmd_mac_viewer ;;
  dmg) cmd_dmg ;;
  pkg) cmd_pkg ;;
  viewer) cmd_viewer ;;
  viewer-build) cmd_viewer_build ;;
  viewer-zip) cmd_viewer_zip ;;
  notes) cmd_notes ;;
  sums) cmd_sums ;;
  cask) cmd_cask ;;
  all)
    cmd_check
    rm -rf "$OUT"
    cmd_host
    cmd_mac_viewer
    cmd_dmg
    cmd_pkg
    cmd_viewer
    cmd_notes
    say "SHA256SUMS"
    cmd_sums
    cmd_cask
    say "release $VERSION ($GLIDE_BUILD_COMMIT) in $OUT"
    ls -l "$OUT" ;;
  -h|--help) sed -n '2,/^set -Eeuo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
