#!/bin/bash
# Builds a Glide release locally, without CI: the same steps .github/workflows/release.yml runs.
#
#   tools/release.sh                 everything below, into dist/release/<version>/
#   tools/release.sh host            Glide-Host-<ver>-macos-<arch>.zip   (macOS only)
#   tools/release.sh dmg             Glide-Host-<ver>-macos-<arch>.dmg from that zip (macOS only;
#                                    after notarizing, so the DMG holds the stapled app)
#   tools/release.sh viewer          Glide-Viewer-<ver>-windows-x64.zip  (macOS or Linux, MinGW-w64)
#   tools/release.sh notes           RELEASE_NOTES.md from CHANGELOG.md
#   tools/release.sh sums            SHA256SUMS over the zips in the output folder
#   tools/release.sh cask            glide-host.rb, the Homebrew cask, from SHA256SUMS
#                                    (packaging/homebrew/README.md)
#   tools/release.sh check           version consistency + CHANGELOG entry, nothing is built
#
# Options (environment):
#   GLIDE_RELEASE_OUT=DIR     output folder (default: dist/release/<version>)
#   GLIDE_SKIP_TESTS=1        skip glide-selftest and cargo test before packaging
#   GLIDE_HOST_ARCHS="arm64 x86_64"  universal host binary (default: arm64 only; see docs/INSTALL.md)
#   GLIDE_SIGN_ID, GLIDE_BUNDLE_ID, GLIDE_HARDENED_RUNTIME: see tools/make-host-app.sh and
#                             tools/build-env.sh (.dev/build.env is read as usual)
# The version is the VERSION file (tools/version.sh). Nothing is uploaded or tagged.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
VERSION="$("$ROOT/tools/version.sh")"
OUT="${GLIDE_RELEASE_OUT:-$ROOT/dist/release/$VERSION}"
DEFAULT_BUNDLE_ID="io.github.sudobrandino.glide.host"
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

cmd_host() {
  [[ "$(uname -s)" == Darwin ]] || die "the host app can only be built on macOS"
  # A personal bundle id or development certificate (from .dev/build.env) would end up in a
  # public download. Override on the command line, or opt in with GLIDE_RELEASE_CUSTOM_ID=1.
  if [[ "$GLIDE_BUNDLE_ID" != "$DEFAULT_BUNDLE_ID" && "${GLIDE_RELEASE_CUSTOM_ID:-0}" != 1 ]]; then
    die "GLIDE_BUNDLE_ID is '$GLIDE_BUNDLE_ID' (from .dev/build.env?), not the public default
       '$DEFAULT_BUNDLE_ID'. Testers' LaunchAgent label and privacy grants key on it. Run
       GLIDE_BUNDLE_ID=$DEFAULT_BUNDLE_ID GLIDE_SIGN_ID=- tools/release.sh, or set
       GLIDE_RELEASE_CUSTOM_ID=1 to build with it anyway."
  fi
  case "$GLIDE_SIGN_ID" in
    -|"Developer ID Application:"*) ;;
    *) [[ "${GLIDE_RELEASE_CUSTOM_ID:-0}" == 1 ]] || die "GLIDE_SIGN_ID is '$GLIDE_SIGN_ID' (from .dev/build.env?). Public releases
       are signed ad hoc (GLIDE_SIGN_ID=-) or with a Developer ID; a development certificate embeds
       its name (often an email address) in the app. Set GLIDE_RELEASE_CUSTOM_ID=1 to use it anyway."
       echo "warning: signing with '$GLIDE_SIGN_ID' (GLIDE_RELEASE_CUSTOM_ID=1)" >&2 ;;
  esac
  mkdir -p "$OUT"
  if [[ "${GLIDE_SKIP_TESTS:-0}" != 1 ]]; then
    say "host: release build + selftest"
    (cd "$ROOT/mac" && swift build -c release --build-system native >/dev/null)
    "$ROOT/mac/.build/release/glide-selftest" "$ROOT/docs/test-vectors.json" | tail -1
  fi
  local stage; stage="$(mktemp -d)"
  say "host: Glide Host.app (sign id: $GLIDE_SIGN_ID, bundle id: $GLIDE_BUNDLE_ID)"
  GLIDE_APP_OUT="$stage/Glide Host.app" "$ROOT/tools/make-host-app.sh"
  local app="$stage/Glide Host.app" bin archs arch_name
  bin="$app/Contents/MacOS/glide-host"
  archs="$(lipo -archs "$bin")"
  case "$archs" in
    arm64) arch_name=arm64 ;;
    x86_64) arch_name=x86_64 ;;
    *arm64*x86_64*|*x86_64*arm64*) arch_name=universal ;;
    *) die "unexpected host architectures: $archs" ;;
  esac
  local got; got="$("$bin" --version)"
  [[ "$got" == "glide-host $VERSION ("*")"* ]] || die "glide-host --version says '$got', expected $VERSION"
  echo "$got"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$VERSION" ]] \
    || die "Info.plist CFBundleShortVersionString != $VERSION"
  local zip="$OUT/Glide-Host-$VERSION-macos-$arch_name.zip"
  rm -f "$OUT"/Glide-Host-"$VERSION"-macos-*.zip
  # ditto keeps the bundle's symlinks, extended attributes and code signature intact.
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  rm -rf "$stage"
  echo "wrote $zip"
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
    echo "wrote $dmg"
  done
}

cmd_viewer() {
  mkdir -p "$OUT"
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
  local exe="$ROOT/windows/target/$TARGET/release/glide-client.exe"
  [[ -f "$exe" ]] || die "build produced no $exe"
  # Static CRT (+crt-static in windows/.cargo/config.toml): no MinGW runtime DLLs allowed.
  if command -v x86_64-w64-mingw32-objdump >/dev/null; then
    if x86_64-w64-mingw32-objdump -p "$exe" | grep -iE 'DLL Name: (libgcc|libwinpthread|libstdc)'; then
      die "glide-client.exe links MinGW runtime DLLs"
    fi
  fi
  local stage; stage="$(mktemp -d)"
  cp "$exe" "$stage/glide-client.exe"
  # Text files for Notepad: CRLF line endings.
  sed 's/$/\r/' "$ROOT/LICENSE" > "$stage/LICENSE.txt"
  sed 's/$/\r/' > "$stage/README.txt" <<EOF
Glide viewer $VERSION (Windows 10/11 x64), protocol v2, commit $GLIDE_BUILD_COMMIT

Run glide-client.exe. With no arguments it waits for the Mac to connect on TCP port 7420
(the host dials out with: glide-host --connect THIS-PC:7420). To connect to the Mac instead:

    glide-client.exe 192.168.1.50

The first connection pairs this PC with the Mac: both screens show the same 6-digit code;
confirm on both only if they match. Settings: %APPDATA%\\Glide\\config.json.
Requires a GPU with HEVC hardware decode and the "HEVC Video Extensions" from the Microsoft Store.

Install guide (SmartScreen, firewall, pairing, troubleshooting):
https://github.com/sudoBrandino/glide/blob/v$VERSION/docs/INSTALL.md
All viewer options: glide-client.exe --help
EOF
  rm -f "$OUT/$VIEWER_ZIP"
  (cd "$stage" && zip -X -q "$OUT/$VIEWER_ZIP" glide-client.exe README.txt LICENSE.txt)
  rm -rf "$stage"
  echo "wrote $OUT/$VIEWER_ZIP"
}

cmd_notes() {
  mkdir -p "$OUT"
  local notes="$OUT/RELEASE_NOTES.md" body
  # Relative links (docs/INSTALL.md) don't resolve on the release page: point them at the tag.
  body="$(changelog_section "$VERSION" | sed -E "s#\]\((docs/|[A-Z]+\.md)#](https://github.com/sudoBrandino/glide/blob/v$VERSION/\1#g")"
  [[ -n "${body//[[:space:]]/}" ]] || die "CHANGELOG.md has no '## [$VERSION]' section"
  {
    echo "$body"
    echo
    echo "## Downloads"
    echo
    echo "| File | For |"
    echo "|---|---|"
    for z in "$OUT"/Glide-Host-"$VERSION"-macos-*.dmg "$OUT"/Glide-Host-"$VERSION"-macos-*.zip; do
      [[ -e "$z" ]] || continue
      local desc="macOS 14+ on Apple silicon"
      [[ "$z" == *-universal.* ]] && desc="macOS 14+, universal (Apple silicon; Intel untested, see the install guide)"
      if [[ "$z" == *.dmg ]]; then
        echo "| \`$(basename "$z")\` | **Mac host, start here:** open it, drag Glide Host to Applications, open it; its setup window does the rest. $desc |"
      else
        echo "| \`$(basename "$z")\` | Mac host as a zip (install script, Homebrew), $desc. Signed ad hoc, not notarized |"
      fi
    done
    echo "| \`$VIEWER_ZIP\` | Windows viewer: \`glide-client.exe\`, Windows 10/11 x64 |"
    echo "| \`SHA256SUMS\` | Checksums: \`shasum -a 256 -c SHA256SUMS\` (Mac) or \`Get-FileHash\` (Windows) |"
    echo
    echo "## Install"
    echo
    echo "**Mac:** download the \`.dmg\`, drag **Glide Host** to Applications and open it. The app is"
    echo "not notarized, so the first time macOS refuses to open it: go to System Settings → Privacy &"
    echo "Security and click **Open Anyway**. Then the setup window walks through starting at login,"
    echo "the two permissions, the connection and pairing."
    echo
    echo "**Windows:** download the viewer zip, run \`glide-client.exe\` and follow its setup window."
    echo
    echo "From a terminal instead (same result): \`curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/v$VERSION/install.sh | bash\`,"
    echo "or \`brew install --cask sudobrandino/glide/glide-host\` (then \`glide-setup\`). Windows, in PowerShell:"
    echo
    echo '```powershell'
    echo "irm https://raw.githubusercontent.com/sudoBrandino/glide/v$VERSION/install.ps1 | iex"
    echo '```'
    echo
    echo "To install by hand, follow the [install guide](https://github.com/sudoBrandino/glide/blob/v$VERSION/docs/INSTALL.md):"
    echo "the Mac app is not notarized, so macOS blocks it until you clear the quarantine flag, and"
    echo "the host needs the Screen Recording and Accessibility permissions."
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
    zips=(Glide-*.zip Glide-*.dmg)
    [[ ${#zips[@]} -gt 0 ]] || die "no Glide-*.zip in $OUT"
    sha256 "${zips[@]}" > SHA256SUMS
    cat SHA256SUMS )
}

case "${1:-all}" in
  check) cmd_check ;;
  host) cmd_host ;;
  dmg) cmd_dmg ;;
  viewer) cmd_viewer ;;
  notes) cmd_notes ;;
  sums) cmd_sums ;;
  cask) cmd_cask ;;
  all)
    cmd_check
    rm -rf "$OUT"
    cmd_host
    cmd_dmg
    cmd_viewer
    cmd_notes
    say "SHA256SUMS"
    cmd_sums
    cmd_cask
    say "release $VERSION ($GLIDE_BUILD_COMMIT) in $OUT"
    ls -l "$OUT" ;;
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
