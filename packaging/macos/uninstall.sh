#!/bin/bash
# Removes Glide from a Mac for all users: the uninstaller for the .pkg (MDM) installs, also fine
# after install.sh, Homebrew or the .dmg. Shipped inside the host app as
# Contents/Resources/glide-uninstall; MDM admins can run this file as a policy script.
#
#   sudo "/Applications/Glide Host.app/Contents/Resources/glide-uninstall" [--purge] [--keep-viewer]
#
# Stops Glide Host in every GUI session, removes /Library/LaunchAgents/*.glide.host.plist and every
# user's ~/Library/LaunchAgents/*.glide.host.plist, deletes Glide Host.app and Glide Viewer.app
# from /Applications (--keep-viewer keeps the viewer) and forgets the package receipts.
# --purge also deletes every user's Glide settings, keys, pairings, cloud enrollment and log, and
# resets the Screen Recording and Accessibility grants. Configuration profiles (PPPC, managed
# preferences, login items) are removed through the MDM, not here.
set -u

LABELS="dev.brandino.glide.host io.github.sudobrandino.glide.host"
BUNDLE_IDS="$LABELS dev.brandino.glide.viewer"
RECEIPTS="dev.brandino.glide.host.pkg dev.brandino.glide.viewer.pkg"
APPS_DIR="/Applications"

say() { echo "glide-uninstall: $*"; }

gui_uids() {
  ps -axo uid=,comm= | awk '$2 ~ /(^|\/)loginwindow$/ && $1 != 0 { print $1 }' | sort -u
}

home_of() { dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk 'NR == 1 { print $2 }'; }

main() {
  local purge=0 keep_viewer=0 a=""
  for a in "$@"; do
    case "$a" in
      --purge) purge=1 ;;
      --keep-viewer) keep_viewer=1 ;;
      -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
  done
  [[ "$(id -u)" == 0 ]] || { echo "run this with sudo (it changes every user's setup)" >&2; exit 1; }

  local uid="" l="" user="" home="" f="" id=""
  # Running hosts and viewers, and their launchd jobs (system-wide agent, install.sh's agents and
  # the app's login item share the label).
  for uid in $(gui_uids); do
    user="$(id -un "$uid" 2>/dev/null)" || continue
    if [[ -x "$APPS_DIR/Glide Host.app/Contents/MacOS/glide-host" ]]; then
      launchctl asuser "$uid" sudo -u "$user" "$APPS_DIR/Glide Host.app/Contents/MacOS/glide-host" \
        --login-item off >/dev/null 2>&1 || true
    fi
    for l in $LABELS; do launchctl bootout "gui/$uid/$l" 2>/dev/null && say "stopped $l for $user"; done
  done

  rm -f /Library/LaunchAgents/*.glide.host.plist && say "removed the system-wide LaunchAgent"
  while read -r user uid; do
    [[ "$uid" -ge 500 ]] 2>/dev/null || continue
    home="$(home_of "$user")"
    [[ -n "$home" && -d "$home" ]] || continue
    for f in "$home/Library/LaunchAgents/"*.glide.host.plist; do
      [[ -e "$f" ]] && rm -f "$f" && say "removed $f"
    done
    if [[ $purge == 1 ]]; then
      rm -rf "$home/Library/Application Support/Glide" "$home/Library/Logs/glide-host.log"
      say "removed $user's Glide settings, keys, pairings and log"
    fi
  done < <(dscl . -list /Users UniqueID 2>/dev/null)

  rm -rf "$APPS_DIR/Glide Host.app" && say "removed $APPS_DIR/Glide Host.app"
  if [[ $keep_viewer != 1 ]]; then
    pkill -x glide-viewer 2>/dev/null || true
    rm -rf "$APPS_DIR/Glide Viewer.app" && say "removed $APPS_DIR/Glide Viewer.app"
  fi
  for id in $RECEIPTS; do pkgutil --forget "$id" >/dev/null 2>&1 && say "forgot receipt $id"; done
  if [[ $purge == 1 ]]; then
    for id in $BUNDLE_IDS; do
      tccutil reset ScreenCapture "$id" >/dev/null 2>&1 || true
      tccutil reset Accessibility "$id" >/dev/null 2>&1 || true
    done
    say "reset the Screen Recording and Accessibility grants"
  fi
  say "done"
}

main "$@"
