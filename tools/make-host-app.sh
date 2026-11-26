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
#   GLIDE_SIGN_KEYCHAIN           keychain holding the identity (see tools/mac-sign.sh)
#   GLIDE_BUILD_COMMIT=SHA        commit recorded in Info.plist (default: git rev-parse HEAD)
# The version comes from the VERSION file (tools/version.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
# shellcheck source=tools/mac-sign.sh
source "$ROOT/tools/mac-sign.sh"
OUT="${GLIDE_APP_OUT:-$ROOT/dist/Glide Host.app}"
VERSION="$("$ROOT/tools/version.sh")"
if [[ -z "${GLIDE_BUILD_COMMIT:-}" ]]; then
  GLIDE_BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] || GLIDE_BUILD_COMMIT+="-dirty"
fi

BINS=()
# glide-viewer (control a Windows PC from this Mac, docs/WINDOWS_HOST.md) ships in the same app,
# so Homebrew and the install script put both on PATH.
VIEWER_BINS=()
if [[ -z "${GLIDE_HOST_ARCHS:-}" ]]; then
  (cd "$ROOT/mac" && swift build -c release --build-system native >/dev/null)
  BINS+=("$ROOT/mac/.build/release/glide-host")
  VIEWER_BINS+=("$ROOT/mac/.build/release/glide-viewer")
else
  for arch in $GLIDE_HOST_ARCHS; do
    for product in glide-host glide-viewer; do
      (cd "$ROOT/mac" && swift build -c release --build-system native --product "$product" \
        --triple "$arch-apple-macosx14.0" >/dev/null)
    done
    BINS+=("$ROOT/mac/.build/$arch-apple-macosx/release/glide-host")
    VIEWER_BINS+=("$ROOT/mac/.build/$arch-apple-macosx/release/glide-viewer")
  done
fi
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
if [[ ${#BINS[@]} -gt 1 ]]; then
  lipo -create -output "$OUT/Contents/MacOS/glide-host" "${BINS[@]}"
  lipo -create -output "$OUT/Contents/MacOS/glide-viewer" "${VIEWER_BINS[@]}"
else
  cp "${BINS[0]}" "$OUT/Contents/MacOS/glide-host"
  cp "${VIEWER_BINS[0]}" "$OUT/Contents/MacOS/glide-viewer"
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
  <key>NSLocalNetworkUsageDescription</key><string>Glide Host accepts connections from your paired viewers and connects to the PC you set up on your local network.</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
# The installer and setup assistant, shipped inside the app so Homebrew (and anyone with only the
# app) can run it: the cask links it as `glide-setup`. It finds the app it lives in.
install -m 0755 "$ROOT/install.sh" "$OUT/Contents/Resources/glide-setup"
# The all-users uninstaller for .pkg (MDM) installs: sudo ".../Contents/Resources/glide-uninstall".
install -m 0755 "$ROOT/packaging/macos/uninstall.sh" "$OUT/Contents/Resources/glide-uninstall"
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
# Hardened runtime entitlements: none are needed (packaging/macos/glide-host.entitlements says why).
# Nested code first: the bundle's signature seals glide-viewer, which needs its own signature.
glide_sign_app "$OUT/Contents/MacOS/glide-viewer" "${GLIDE_BUNDLE_ID%.host}.viewer" \
  "$ROOT/packaging/macos/glide-viewer.entitlements"
glide_sign_app "$OUT" "$GLIDE_BUNDLE_ID" "$ROOT/packaging/macos/glide-host.entitlements"
echo "built $OUT ($VERSION, $GLIDE_BUILD_COMMIT, $(lipo -archs "$OUT/Contents/MacOS/glide-host"), $GLIDE_BUNDLE_ID)"
