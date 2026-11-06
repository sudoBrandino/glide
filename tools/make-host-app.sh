#!/bin/bash
# Builds and signs "Glide Host.app" (menu-bar-less agent app wrapping glide-host).
# Signing with a stable identity keeps macOS privacy grants (Screen Recording, Accessibility)
# valid across rebuilds. Override with GLIDE_SIGN_ID="<identity or hash>" or GLIDE_SIGN_ID=- (ad hoc).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_ID="${GLIDE_SIGN_ID:-Apple Development: you@example.com (TEAMID1234)}"
OUT="$ROOT/dist/Glide Host.app"
VERSION="0.1.$(date +%Y%m%d%H%M)"

(cd "$ROOT/mac" && swift build -c release --build-system native >/dev/null)
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$ROOT/mac/.build/release/glide-host" "$OUT/Contents/MacOS/glide-host"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.sudobrandino.glide.host</string>
  <key>CFBundleName</key><string>Glide Host</string>
  <key>CFBundleDisplayName</key><string>Glide Host</string>
  <key>CFBundleExecutable</key><string>glide-host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --timestamp=none --sign "$SIGN_ID" --identifier io.github.sudobrandino.glide.host "$OUT"
codesign --verify --verbose=1 "$OUT" 2>&1 | tail -1
codesign -dr - "$OUT" 2>&1 | grep designated
echo "built $OUT ($VERSION)"
