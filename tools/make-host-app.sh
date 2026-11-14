#!/bin/bash
# Builds and signs "Glide Host.app" (menu-bar-less agent app wrapping glide-host).
# Signing with a stable identity keeps macOS privacy grants (Screen Recording, Accessibility)
# valid across rebuilds: set GLIDE_SIGN_ID="<identity or hash>". The default is ad hoc ("-").
# GLIDE_BUNDLE_ID sets the bundle identifier. See tools/build-env.sh (.dev/build.env).
#
# Optional (used by tools/release.sh and the release workflow):
#   GLIDE_APP_OUT=PATH            where to write the app (default: dist/Glide Host.app)
#   GLIDE_HOST_ARCHS="arm64 x86_64"  build each architecture and lipo them into a universal binary
#                                 (default: the build machine's architecture only)
#   GLIDE_HARDENED_RUNTIME=1      sign with the hardened runtime and a secure timestamp, as
#                                 notarization requires (needs a Developer ID GLIDE_SIGN_ID)
#   GLIDE_BUILD_COMMIT=SHA        commit recorded in Info.plist (default: git rev-parse HEAD)
# The version comes from the VERSION file (tools/version.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
SIGN_ID="$GLIDE_SIGN_ID"
OUT="${GLIDE_APP_OUT:-$ROOT/dist/Glide Host.app}"
VERSION="$("$ROOT/tools/version.sh")"
if [[ -z "${GLIDE_BUILD_COMMIT:-}" ]]; then
  GLIDE_BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] || GLIDE_BUILD_COMMIT+="-dirty"
fi

BINS=()
if [[ -z "${GLIDE_HOST_ARCHS:-}" ]]; then
  (cd "$ROOT/mac" && swift build -c release --build-system native >/dev/null)
  BINS+=("$ROOT/mac/.build/release/glide-host")
else
  for arch in $GLIDE_HOST_ARCHS; do
    (cd "$ROOT/mac" && swift build -c release --build-system native --product glide-host \
      --triple "$arch-apple-macosx14.0" >/dev/null)
    BINS+=("$ROOT/mac/.build/$arch-apple-macosx/release/glide-host")
  done
fi
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
if [[ ${#BINS[@]} -gt 1 ]]; then
  lipo -create -output "$OUT/Contents/MacOS/glide-host" "${BINS[@]}"
else
  cp "${BINS[0]}" "$OUT/Contents/MacOS/glide-host"
fi
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$GLIDE_BUNDLE_ID</string>
  <key>CFBundleName</key><string>Glide Host</string>
  <key>CFBundleDisplayName</key><string>Glide Host</string>
  <key>CFBundleExecutable</key><string>glide-host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>GlideCommit</key><string>$GLIDE_BUILD_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
# The installer and setup assistant, shipped inside the app so Homebrew (and anyone with only the
# app) can run it: the cask links it as `glide-setup`. It finds the app it lives in.
install -m 0755 "$ROOT/install.sh" "$OUT/Contents/Resources/glide-setup"
install -m 0644 "$ROOT/mac/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
# The login item (setup window → Start at Login registers it with SMAppService). Same label as the
# install script's LaunchAgent, so launchd never runs both. KeepAlive: restart after a crash, and
# after "Restart Glide Host" / a Screen Recording grant (the host just exits).
mkdir -p "$OUT/Contents/Library/LaunchAgents"
cat > "$OUT/Contents/Library/LaunchAgents/$GLIDE_BUNDLE_ID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$GLIDE_BUNDLE_ID</string>
  <key>BundleProgram</key><string>Contents/MacOS/glide-host</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Library/LaunchAgents/$GLIDE_BUNDLE_ID.plist" >/dev/null
SIGN_FLAGS=(--timestamp=none)
[[ "${GLIDE_HARDENED_RUNTIME:-0}" == 1 ]] && SIGN_FLAGS=(--options runtime --timestamp)
codesign --force "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" --identifier "$GLIDE_BUNDLE_ID" "$OUT"
codesign --verify --strict --verbose=1 "$OUT" 2>&1 | tail -1
codesign -dr - "$OUT" 2>&1 | grep designated
echo "built $OUT ($VERSION, $GLIDE_BUILD_COMMIT, $(lipo -archs "$OUT/Contents/MacOS/glide-host"), $GLIDE_BUNDLE_ID)"
