#!/bin/bash
# Installs Glide Host.app to ~/Applications and a per-user LaunchAgent that keeps it running
# (starts at login, restarts if it exits). No sudo needed.
#   install-host.sh            install/update app + agent, (re)start it
#   install-host.sh --no-start install/update only
#   install-host.sh --uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Glide Host.app"
LABEL="io.github.sudobrandino.glide.host"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; rm -rf "$APP"
  echo "uninstalled (config kept in ~/Library/Application Support/Glide)"; exit 0
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -rf "$APP"
cp -R "$ROOT/dist/Glide Host.app" "$APP"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/glide-host</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/glide-host.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/glide-host.log</string>
</dict>
</plist>
PLIST
echo "installed $APP and $PLIST"
if [[ "${1:-}" != "--no-start" ]]; then
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "started ($LABEL); log: ~/Library/Logs/glide-host.log"
fi
