#!/bin/bash
# shellcheck disable=SC2016  # the bash -c snippets get their values as positional arguments
# Exercises install.sh without touching this Mac's real Glide setup: a throwaway home folder,
# config folder and bundle id, and --no-start, so no LaunchAgent is ever loaded.
#   tools/test-install.sh [PATH-TO-glide-host]   (default: mac/.build/release/glide-host)
# The binary only has to answer --set-connect; the app bundle around it is assembled here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/mac/.build/release/glide-host}"
[[ -x "$BIN" ]] || { echo "no glide-host binary at $BIN (swift build -c release in mac/)" >&2; exit 1; }
LABEL="org.example.installtest.glide.host"   # ends in .glide.host like the real ones
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GLIDE_HOST_CONFIG_DIR="$T/cfg" NO_COLOR=1
mkdir -p "$HOME"
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }
run() { "$ROOT/install.sh" "$@" >"$T/out" 2>&1; }

SRC="$T/src/Glide Host.app"
mkdir -p "$SRC/Contents/MacOS" "$SRC/Contents/Resources"
cp "$BIN" "$SRC/Contents/MacOS/glide-host"
cat > "$SRC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>glide-host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.9.9</string>
</dict></plist>
PLIST
install -m 0755 "$ROOT/install.sh" "$SRC/Contents/Resources/glide-setup"
codesign --force --sign - --identifier "$LABEL" "$SRC" 2>/dev/null

APP="$HOME/Applications/Glide Host.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
connect() { plutil -extract connect raw -o - "$GLIDE_HOST_CONFIG_DIR/host.json" 2>/dev/null || true; }

check "--help prints the usage" bash -c '"$0/install.sh" --help | grep -q -- "--connect HOST"' "$ROOT"
check "conflicting options are refused" bash -c '! "$0/install.sh" --connect a --listen >/dev/null 2>&1' "$ROOT"

check "install from an app folder" run --yes --no-start --app "$SRC" --connect 127.0.0.1:9
check "  app copied to ~/Applications" test -x "$APP/Contents/MacOS/glide-host"
check "  LaunchAgent is valid" plutil -lint -s "$PLIST"
check "  LaunchAgent label is the bundle id" test "$(plutil -extract Label raw -o - "$PLIST")" == "$LABEL"
check "  KeepAlive tied to the binary (PathState)" \
  bash -c '/usr/libexec/PlistBuddy -c "Print :KeepAlive:PathState" "$0" | grep -qxF "    $1/Contents/MacOS/glide-host = true"' "$PLIST" "$APP"
check "  connect target saved" test "$(connect)" == "127.0.0.1:9"
check "  agent not loaded (--no-start)" bash -c '! launchctl print "gui/$(id -u)/$0" >/dev/null 2>&1' "$LABEL"

check "reinstall with --listen" run --yes --no-start --app "$SRC" --listen
check "  says reinstalling" grep -q "reinstalling Glide Host 9.9.9" "$T/out"
check "  connect target removed" test -z "$(connect)"

OTHER="$HOME/Library/LaunchAgents/com.example.old.glide.host.plist"
cp "$PLIST" "$OTHER"
check "another Glide agent blocks an unattended install" bash -c '! "$0" --yes --no-start --app "$1" >/dev/null 2>&1' "$ROOT/install.sh" "$SRC"
check "  --replace-other removes it" run --yes --no-start --app "$SRC" --replace-other
check "  old agent gone" test ! -e "$OTHER"

ditto -c -k --keepParent "$SRC" "$T/app.zip"
rm -rf "$APP"
check "install from a release zip, piped like curl | bash" \
  bash -c 'bash -s -- --yes --no-start --app "$1" < "$0" >/dev/null 2>&1' "$ROOT/install.sh" "$T/app.zip"
check "  app installed" test -x "$APP/Contents/MacOS/glide-host"

check "glide-setup inside the app installs in place" \
  bash -c '"$0/Contents/Resources/glide-setup" --yes --no-start >/dev/null 2>&1' "$APP"
check "  agent points into that app" \
  test "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" == "$(realpath "$APP")/Contents/MacOS/glide-host"

check "uninstall --purge" run --uninstall --purge
check "  app removed" test ! -e "$APP"
check "  agent removed" test ! -e "$PLIST"
check "  settings removed" test ! -e "$GLIDE_HOST_CONFIG_DIR"

if [[ $fails -gt 0 ]]; then echo "$fails check(s) failed; last installer output:"; cat "$T/out"; exit 1; fi
echo "all install.sh checks passed"
