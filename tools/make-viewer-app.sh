#!/bin/bash
# Builds and signs "Glide Viewer.app", the Mac viewer for a Windows host (docs/WINDOWS_HOST.md),
# around the glide-viewer executable. The counterpart of tools/make-host-app.sh, with the same
# options; GLIDE_VIEWER_BUNDLE_ID sets the bundle identifier (default dev.brandino.glide.viewer,
# tools/build-env.sh).
#
#   GLIDE_VIEWER_APP_OUT=PATH     where to write the app (default: dist/Glide Viewer.app)
#   GLIDE_HOST_ARCHS="arm64 x86_64"  universal binary, as for the host (default: this machine's)
#   GLIDE_SIGN_ID, GLIDE_HARDENED_RUNTIME, GLIDE_SIGN_KEYCHAIN: see tools/mac-sign.sh
#   GLIDE_BUILD_COMMIT=SHA        commit recorded in Info.plist (default: git rev-parse HEAD)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
# shellcheck source=tools/mac-sign.sh
source "$ROOT/tools/mac-sign.sh"
OUT="${GLIDE_VIEWER_APP_OUT:-$ROOT/dist/Glide Viewer.app}"
VERSION="$("$ROOT/tools/version.sh")"
if [[ -z "${GLIDE_BUILD_COMMIT:-}" ]]; then
  GLIDE_BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  [[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] || GLIDE_BUILD_COMMIT+="-dirty"
fi

BINS=()
if [[ -z "${GLIDE_HOST_ARCHS:-}" ]]; then
  (cd "$ROOT/mac" && swift build -c release --build-system native --product glide-viewer >/dev/null)
  BINS+=("$ROOT/mac/.build/release/glide-viewer")
else
  for arch in $GLIDE_HOST_ARCHS; do
    (cd "$ROOT/mac" && swift build -c release --build-system native --product glide-viewer \
      --triple "$arch-apple-macosx14.0" >/dev/null)
    BINS+=("$ROOT/mac/.build/$arch-apple-macosx/release/glide-viewer")
  done
fi
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
if [[ ${#BINS[@]} -gt 1 ]]; then
  lipo -create -output "$OUT/Contents/MacOS/glide-viewer" "${BINS[@]}"
else
  cp "${BINS[0]}" "$OUT/Contents/MacOS/glide-viewer"
fi
# A regular app (Dock icon, menu bar), unlike the host. Privacy keys: Local Network (macOS 15+
# asks before the first connection to a PC on the LAN). Accessibility, which the session's
# keyboard capture uses when granted, has no Info.plist key.
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$GLIDE_VIEWER_BUNDLE_ID</string>
  <key>CFBundleName</key><string>Glide Viewer</string>
  <key>CFBundleDisplayName</key><string>Glide Viewer</string>
  <key>CFBundleExecutable</key><string>glide-viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>GlideCommit</key><string>$GLIDE_BUILD_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Glide Viewer connects to the Windows PCs you add, on your local network.</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
install -m 0644 "$ROOT/mac/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
glide_sign_app "$OUT" "$GLIDE_VIEWER_BUNDLE_ID" "$ROOT/packaging/macos/glide-viewer.entitlements"
echo "built $OUT ($VERSION, $GLIDE_BUILD_COMMIT, $(lipo -archs "$OUT/Contents/MacOS/glide-viewer"), $GLIDE_VIEWER_BUNDLE_ID)"
