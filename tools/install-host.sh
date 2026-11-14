#!/bin/bash
# Installs Glide Host.app to ~/Applications and a per-user LaunchAgent that keeps it running
# (starts at login, restarts if it exits). No sudo needed.
#   install-host.sh            install/update app + agent, (re)start it
#   install-host.sh --no-start install/update only
#   install-host.sh --uninstall
# The LaunchAgent label is the app's bundle identifier (GLIDE_BUNDLE_ID, see tools/build-env.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Glide Host.app"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"
LABEL="$GLIDE_BUNDLE_ID"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; rm -rf "$APP"
  echo "uninstalled (config kept in ~/Library/Application Support/Glide)"; exit 0
fi

# Only one host can capture at a time. Refuse to add a second agent under a different label
# (for example after changing GLIDE_BUNDLE_ID); uninstall the old one first.
for other in "$HOME/Library/LaunchAgents/"*.glide.host.plist; do
  [[ -e "$other" && "$other" != "$PLIST" ]] || continue
  echo "another Glide Host agent is installed: $other"
  echo "set GLIDE_BUNDLE_ID=$(basename "$other" .plist) to update it, or uninstall it first"
  exit 1
done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout is asynchronous; wait until launchd has really unloaded the agent before re-bootstrapping
for _ in $(seq 1 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.2; done
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
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
    [[ $attempt == 5 ]] && { echo "launchctl bootstrap failed"; exit 1; }
    sleep 1
  done
  echo "started ($LABEL); log: ~/Library/Logs/glide-host.log"
fi
