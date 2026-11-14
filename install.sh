#!/bin/bash
# Glide host installer and setup assistant for macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/sudoBrandino/glide/main/install.sh | bash
#
# Run it in a terminal and it walks through everything: download and verify the release, install
# Glide Host.app and its LaunchAgent, grant Screen Recording and Accessibility, choose which side
# connects, and pair the PC. Run it again at any time to update, re-check the permissions, change
# the connection or pair another viewer. Homebrew installs it as `glide-setup`; source checkouts
# reach it through tools/install-host.sh. No administrator rights are needed.
#
# Options (pass them after `bash -s --` when piping from curl):
#   --version X.Y.Z        install that release instead of the latest one
#   --app PATH             install this Glide Host.app, or a release .zip, instead of downloading
#   --dir DIR              where to put the app (default: ~/Applications)
#   --connect HOST[:PORT]  the Mac dials the viewer at HOST (the viewer runs --listen)
#   --listen               the viewer dials the Mac (the Mac listens on port 7420)
#   --yes, -y              unattended: no questions, keep the current connection settings, skip
#                          the permission and pairing steps
#   --no-start             install without starting the host
#   --replace-other        remove other Glide Host LaunchAgents (older bundle ids) without asking
#   --uninstall [--purge]  remove the app and the LaunchAgent; --purge also removes the settings,
#                          the pairings, the log and the privacy grants
#   --label ID             LaunchAgent label for --uninstall when the app is already gone
#   -h, --help
#
# Environment: GLIDE_REPO (default sudoBrandino/glide), NO_COLOR, GLIDE_HOST_CONFIG_DIR (tests).
#
# Everything runs from main() at the bottom, so a download that stops halfway runs nothing.
# Keep this file compatible with macOS's /bin/bash 3.2.

set -euo pipefail

GLIDE_REPO="${GLIDE_REPO:-sudoBrandino/glide}"
DEFAULT_LABEL="io.github.sudobrandino.glide.host"
DEFAULT_PORT=7420
MIN_MACOS=14

# ---------------------------------------------------------------------------------------------
# Output and questions

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B="" D="" R="" G="" Y="" C="" N=""
fi
step_no=0
step() { step_no=$((step_no + 1)); printf '\n%s%s[%d] %s%s\n' "$B" "$C" "$step_no" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Questions read from the terminal, not stdin: with `curl … | bash`, stdin is this script.
INTERACTIVE=0
tty_ok() { [[ -r /dev/tty && -w /dev/tty ]] && (exec </dev/tty) 2>/dev/null; }

# ask "Question" "default" -> REPLY
ask() {
  local q="$1" def="${2:-}" hint=""
  [[ -n "$def" ]] && hint=" ${D}[$def]${N}"
  if [[ $INTERACTIVE != 1 ]]; then REPLY="$def"; return; fi
  printf '    %s%s ' "$q" "$hint" >/dev/tty
  IFS= read -r REPLY </dev/tty || REPLY=""
  [[ -n "$REPLY" ]] || REPLY="$def"
}

# confirm "Question" y|n -> status
confirm() {
  local def="$2" hint="[Y/n]"
  [[ "$def" == n ]] && hint="[y/N]"
  if [[ $INTERACTIVE != 1 ]]; then [[ "$def" == y ]]; return; fi
  while true; do
    printf '    %s %s%s%s ' "$1" "$D" "$hint" "$N" >/dev/tty
    IFS= read -r REPLY </dev/tty || REPLY=""
    case "${REPLY:-$def}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
    esac
  done
}

# ---------------------------------------------------------------------------------------------
# Helpers

TMP=""
cleanup() {
  perm_stop 2>/dev/null || true   # Ctrl+C while waiting for the permissions
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
xml_escape() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

config_dir() { printf "%s" "${GLIDE_HOST_CONFIG_DIR:-$HOME/Library/Application Support/Glide}"; }
config_get() { # config_get KEY: a top-level string from host.json, or nothing
  local f; f="$(config_dir)/host.json"
  [[ -f "$f" ]] && plutil -extract "$1" raw -o - "$f" 2>/dev/null || true
}

agent_loaded() { launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }
agent_pid() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | awk '$1 == "pid" { print $3; exit }'; }

stop_agent() { # stop_agent LABEL: unload and wait, since bootout is asynchronous
  local label="$1" i
  agent_loaded "$label" || return 0
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  for i in $(seq 1 50); do agent_loaded "$label" || return 0; sleep 0.2; done
  warn "launchd has not unloaded $label yet"
}

# The Mac's own LAN address, for the viewer's command line.
lan_address() {
  local ifc
  ifc="$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')"
  [[ -n "$ifc" ]] && ipconfig getifaddr "$ifc" 2>/dev/null && return
  ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
}

with_port() { [[ "$1" == *:* ]] && printf '%s' "$1" || printf '%s:%s' "$1" "$DEFAULT_PORT"; }

port_open() { /usr/bin/nc -z -G 3 "${1%:*}" "${1##*:}" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------------------
# Options

OPT_VERSION="" OPT_APP="" OPT_DIR="" OPT_CONNECT="" OPT_LISTEN=0 OPT_YES=0 OPT_NO_START=0
OPT_REPLACE_OTHER=0 OPT_UNINSTALL=0 OPT_PURGE=0 OPT_LABEL=""

usage() {
  if [[ -f "$0" ]]; then sed -n '2,/^# Environment/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d'
  else echo "Options: see the top of https://github.com/$GLIDE_REPO/blob/main/install.sh"; fi
  exit "${1:-0}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) OPT_VERSION="${2:?--version needs a value}"; OPT_VERSION="${OPT_VERSION#v}"; shift ;;
      --app) OPT_APP="${2:?--app needs a path}"; shift ;;
      --dir) OPT_DIR="${2:?--dir needs a path}"; shift ;;
      --connect) OPT_CONNECT="${2:?--connect needs HOST[:PORT]}"; shift ;;
      --listen) OPT_LISTEN=1 ;;
      -y|--yes) OPT_YES=1 ;;
      --no-start) OPT_NO_START=1 ;;
      --replace-other) OPT_REPLACE_OTHER=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) OPT_PURGE=1 ;;
      --label) OPT_LABEL="${2:?--label needs a value}"; shift ;;
      -h|--help) usage 0 ;;
      *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
  done
  [[ -n "$OPT_CONNECT" && $OPT_LISTEN == 1 ]] && die "--connect and --listen exclude each other"
  [[ -n "$OPT_APP" && -n "$OPT_VERSION" ]] && die "--app and --version exclude each other"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Steps

preflight() {
  [[ "$(uname -s)" == Darwin ]] || die "the Glide host runs on macOS. On the Windows PC, use install.ps1 (see docs/INSTALL.md)."
  [[ "$(id -u)" != 0 ]] || die "run this as your own user, not with sudo: the host is a per-user LaunchAgent."
  local v; v="$(sw_vers -productVersion)"
  [[ "${v%%.*}" -ge $MIN_MACOS ]] || die "Glide needs macOS $MIN_MACOS or later (this Mac runs $v)."
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]]; then
    warn "This Mac has an Intel processor. Intel Macs have no hardware HEVC 4:4:4 encoder, so Glide does not support them yet."
    confirm "Install anyway?" n || exit 1
  fi
}

# Is this script running from inside an installed Glide Host.app (Homebrew's glide-setup)?
SELF_APP=""
detect_self_app() {
  local me=""
  me="$(realpath "$0" 2>/dev/null || true)"
  case "$me" in
    */Contents/Resources/glide-setup) SELF_APP="${me%/Contents/Resources/glide-setup}" ;;
  esac
  return 0
}

# Sets SRC_APP to a Glide Host.app to install (in a temporary folder unless it's SELF_APP).
SRC_APP="" SRC_DESC=""
obtain_app() {
  if [[ -n "$OPT_APP" ]]; then
    step "Using $OPT_APP"
    if [[ -d "$OPT_APP" ]]; then
      SRC_APP="$(cd "$OPT_APP" && pwd)"
    elif [[ -f "$OPT_APP" && "$OPT_APP" == *.zip ]]; then
      TMP="$(mktemp -d)"
      ditto -x -k "$OPT_APP" "$TMP/unzip" || die "could not unzip $OPT_APP"
      SRC_APP="$(find "$TMP/unzip" -maxdepth 2 -name '*.app' -type d | head -1)"
      [[ -n "$SRC_APP" ]] || die "$OPT_APP holds no .app"
    else
      die "--app must be a Glide Host.app folder or a release .zip"
    fi
    SRC_DESC="$OPT_APP"
    return
  fi
  if [[ -n "$SELF_APP" ]]; then
    SRC_APP="$SELF_APP"; SRC_DESC="this app ($SELF_APP)"
    return
  fi
  download_release
}

download_release() {
  local tag="" ver="" name="" want="" got="" base=""
  step "Downloading Glide Host"
  command -v curl >/dev/null || die "curl is missing"
  if [[ -n "$OPT_VERSION" ]]; then
    ver="$OPT_VERSION"
  else
    # /releases/latest redirects to /releases/tag/vX.Y.Z: no API call, no rate limit, no JSON.
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$GLIDE_REPO/releases/latest")" \
      || die "could not reach github.com"
    tag="${tag##*/}"
    [[ "$tag" == v[0-9]* ]] || die "github.com/$GLIDE_REPO has no published release yet"
    ver="${tag#v}"
  fi
  base="https://github.com/$GLIDE_REPO/releases/download/v$ver"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/SHA256SUMS" "$base/SHA256SUMS" || die "release v$ver not found (no SHA256SUMS at $base)"
  # Prefer the arm64 build; fall back to a universal one.
  for name in "Glide-Host-$ver-macos-arm64.zip" "Glide-Host-$ver-macos-universal.zip"; do
    want="$(awk -v f="$name" '$2 == f || $2 == "*" f { print $1; exit }' "$TMP/SHA256SUMS")"
    [[ -n "$want" ]] && break
  done
  [[ -n "$want" ]] || die "release v$ver has no Mac host download"
  info "release v$ver: $name"
  curl -fL --progress-bar -o "$TMP/$name" "$base/$name" || die "download failed"
  got="$(shasum -a 256 "$TMP/$name" | awk '{ print $1 }')"
  [[ "$got" == "$want" ]] || die "checksum mismatch for $name (expected $want, got $got). Not installing."
  ok "checksum matches SHA256SUMS"
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    if gh attestation verify "$TMP/$name" --repo "$GLIDE_REPO" >/dev/null 2>&1; then
      ok "build provenance verified: built from $GLIDE_REPO by its release workflow"
    else
      warn "no valid build provenance attestation (gh attestation verify failed)"
    fi
  fi
  ditto -x -k "$TMP/$name" "$TMP/unzip" || die "could not unzip $name"
  SRC_APP="$TMP/unzip/Glide Host.app"
  [[ -d "$SRC_APP" ]] || die "$name does not contain Glide Host.app"
  SRC_DESC="release v$ver"
}

# Fills LABEL, NEW_VERSION, APP, PLIST from the app to install.
LABEL="" NEW_VERSION="" APP="" PLIST="" OLD_VERSION="" IN_PLACE=0
inspect_app() {
  LABEL="$(plist_get "$SRC_APP" CFBundleIdentifier)"
  NEW_VERSION="$(plist_get "$SRC_APP" CFBundleShortVersionString)"
  [[ -n "$LABEL" && -x "$SRC_APP/Contents/MacOS/glide-host" ]] || die "$SRC_APP is not a Glide Host app"
  codesign --verify --strict "$SRC_APP" 2>/dev/null || die "$SRC_APP has a broken code signature; not installing it"
  if [[ -n "$SELF_APP" && "$SRC_APP" == "$SELF_APP" && -z "$OPT_DIR" ]]; then
    IN_PLACE=1; APP="$SRC_APP"
  else
    APP="${OPT_DIR:-$HOME/Applications}/Glide Host.app"
  fi
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  [[ -d "$APP" ]] && OLD_VERSION="$(plist_get "$APP" CFBundleShortVersionString)"
  if [[ $IN_PLACE == 1 ]]; then
    ok "Glide Host $NEW_VERSION at $APP"
  elif [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    ok "reinstalling Glide Host $NEW_VERSION ($SRC_DESC)"
  elif [[ -n "$OLD_VERSION" ]]; then
    ok "updating Glide Host $OLD_VERSION → $NEW_VERSION ($SRC_DESC)"
  else
    ok "installing Glide Host $NEW_VERSION ($SRC_DESC)"
  fi
  return 0
}

# Only one host can capture the screen. Agents under another label (an older bundle id, or a
# developer build) must go.
remove_other_agents() {
  local others=() f="" other_label=""
  for f in "$HOME/Library/LaunchAgents/"*.glide.host.plist; do
    [[ -e "$f" && "$f" != "$PLIST" ]] && others+=("$f")
  done
  [[ ${#others[@]} -gt 0 ]] || return 0
  step "Another Glide Host is installed"
  for f in "${others[@]}"; do info "$f"; done
  info "Two hosts would fight over screen capture, so the old one has to go."
  if [[ $OPT_REPLACE_OTHER != 1 ]]; then
    if [[ $INTERACTIVE != 1 ]]; then
      die "another Glide Host agent is installed (above). Remove it first, or pass --replace-other."
    fi
    confirm "Stop and remove it?" y || die "not installing next to another Glide Host"
  fi
  for f in "${others[@]}"; do
    other_label="$(basename "$f" .plist)"
    stop_agent "$other_label"
    rm -f "$f"
    ok "removed $other_label (its settings and pairings in $(config_dir) stay)"
  done
}

install_files() {
  step "Installing"
  local label_x="" app_x="" home_x=""
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  stop_agent "$LABEL"
  if [[ $IN_PLACE != 1 ]]; then
    mkdir -p "$(dirname "$APP")"
    rm -rf "$APP"
    # ditto keeps the bundle's symlinks, extended attributes and code signature intact.
    ditto "$SRC_APP" "$APP"
    ok "$APP"
  fi
  # Releases are signed ad hoc and not notarized: a quarantine flag (set by browsers and by
  # Homebrew) would make Gatekeeper refuse to start the app. curl downloads don't carry one.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  label_x="$(xml_escape "$LABEL")" app_x="$(xml_escape "$APP")" home_x="$(xml_escape "$HOME")"
  # KeepAlive PathState: launchd restarts the host whenever it exits, but only while the binary
  # exists. Deleting the app (or `brew uninstall`) leaves nothing retrying in the background, and
  # when an upgrade puts the app back, launchd starts it by itself.
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label_x</string>
  <key>ProgramArguments</key>
  <array><string>$app_x/Contents/MacOS/glide-host</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>$app_x/Contents/MacOS/glide-host</key><true/></dict>
  </dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$home_x/Library/Logs/glide-host.log</string>
  <key>StandardErrorPath</key><string>$home_x/Library/Logs/glide-host.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$PLIST" >/dev/null || die "wrote an invalid $PLIST"
  ok "$PLIST (starts at login, restarts if it exits)"
}

# The app is started through Launch Services (open -a), so macOS attributes permission checks
# and requests to Glide Host and not to this terminal.

# perm_status -> "screen-recording=granted|missing accessibility=granted|missing", or nothing
# when this build has no --permission-status (0.2.0): then the request's own output is used.
perm_status() {
  local f="" line=""
  f="$(mktemp)"
  open -W -n -a "$APP" --stdout "$f" --stderr "$f" --args --permission-status 2>/dev/null || true
  line="$(grep -m1 '^screen-recording=' "$f" || true)"
  rm -f "$f"
  printf '%s' "$line"
}

PERM_PID="" PERM_OUT=""
perm_request() { # background `glide-host --request-permissions`: shows the macOS prompts
  PERM_OUT="$(mktemp)"
  open -W -n -a "$APP" --stdout "$PERM_OUT" --stderr "$PERM_OUT" --args --request-permissions &
  PERM_PID=$!
}

perm_stop() {
  [[ -n "$PERM_PID" ]] || return 0
  pkill -f "$APP/Contents/MacOS/glide-host --request-permissions" 2>/dev/null || true
  wait "$PERM_PID" 2>/dev/null || true
  PERM_PID=""
}

permissions() {
  step "Screen Recording and Accessibility"
  local status="" legacy=0 i="" granted=0
  status="$(perm_status)"
  if [[ -z "$status" ]]; then
    # 0.2.0: --request-permissions prints the status first, then prompts for what's missing.
    legacy=1
    perm_request
    for i in $(seq 1 50); do status="$(head -1 "$PERM_OUT")"; [[ -n "$status" ]] && break; sleep 0.2; done
    status="${status//Screen Recording: /screen-recording=}"; status="${status//Accessibility: /accessibility=}"
    [[ -n "$status" ]] || { perm_stop; warn "could not start Glide Host to check its permissions"; return 0; }
  fi
  if [[ "$status" == *"screen-recording=granted"*"accessibility=granted"* ]]; then
    perm_stop; ok "both granted"; return 0
  fi
  # An update gets a new ad-hoc signature, so a grant made for the previous build can still show
  # as switched on in System Settings without applying. Clear such stale entries so that macOS
  # asks afresh. Nothing is lost: the permission is missing either way.
  if [[ -n "$OLD_VERSION" ]]; then
    perm_stop
    if [[ "$status" == *"screen-recording=missing"* ]]; then tccutil reset ScreenCapture "$LABEL" >/dev/null 2>&1 || true; fi
    if [[ "$status" == *"accessibility=missing"* ]]; then tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true; fi
  fi
  [[ -n "$PERM_PID" ]] || perm_request
  info "macOS asks now. In each dialog choose ${B}Open System Settings${N}, then switch on"
  info "${B}Glide Host${N} under Privacy & Security → Screen Recording, and → Accessibility."
  info "If macOS offers to quit and reopen Glide Host, choose ${B}Later${N}: the installer restarts it."
  info "${D}Waiting for both. Press Enter to skip.${N}"
  i=0
  while kill -0 "$PERM_PID" 2>/dev/null; do
    if read -r -t 1 _ </dev/tty 2>/dev/null; then break; fi
    i=$((i + 1))
    # A fresh process sees a new Screen Recording grant; the waiting one would not until restarted.
    if [[ $legacy == 0 && $((i % 3)) == 0 && "$(perm_status)" == *"screen-recording=granted"*"accessibility=granted"* ]]; then
      granted=1; break
    fi
  done
  # The request exits as soon as it sees both grants, possibly between two polls.
  if [[ $legacy == 0 && $granted == 0 && "$(perm_status)" == *"screen-recording=granted"*"accessibility=granted"* ]]; then
    granted=1
  fi
  if [[ $legacy == 1 ]] && ! kill -0 "$PERM_PID" 2>/dev/null; then
    case "$(tail -1 "$PERM_OUT")" in
      *"Accessibility: granted"*"Screen Recording: granted"*|*"Accessibility: granted"*"grant pending"*) granted=1 ;;
    esac
  fi
  perm_stop
  rm -f "$PERM_OUT"
  if [[ $granted == 1 ]]; then
    ok "both granted"
  else
    warn "not granted yet. Without Screen Recording the viewer stays black; without"
    warn "Accessibility the mouse and keyboard don't work. Grant them later in System Settings"
    warn "and restart the host (menu bar → Restart Glide Host), or run this installer again."
  fi
}

connection() {
  local current="" mode="" addr="" ip="" bin="$APP/Contents/MacOS/glide-host" cfg=""
  cfg="$(config_dir)/host.json"
  current="$(config_get connect)"
  if [[ -n "$OPT_CONNECT" ]]; then
    mode=dial addr="$(with_port "$OPT_CONNECT")"
  elif [[ $OPT_LISTEN == 1 ]]; then
    mode=listen
  elif [[ $INTERACTIVE == 1 ]]; then
    step "How should the Mac and the PC connect?"
    info "1) The PC connects to this Mac ${D}(the Mac listens on port $DEFAULT_PORT)${N}"
    info "2) This Mac connects to the PC ${D}(the PC runs glide-client --listen; use this when the${N}"
    info "   ${D}Mac can reach the PC but not the other way round)${N}"
    [[ -n "$current" ]] && info "${D}Now: the Mac dials $current.${N}"
    ask "Choose 1 or 2:" "$([[ -n "$current" ]] && echo 2 || echo 1)"
    case "$REPLY" in
      2) mode=dial
         ask "The PC's address (name or IP, optionally :port):" "$current"
         [[ -n "$REPLY" ]] || die "no address given"
         addr="$(with_port "$REPLY")" ;;
      *) mode=listen ;;
    esac
  else
    mode=keep
  fi

  case "$mode" in
    dial)
      if [[ "$addr" != "$current" ]]; then
        "$bin" --set-connect "$addr" >/dev/null || die "could not save the connect target"
      fi
      ok "the Mac dials $addr and retries every 2 s while disconnected"
      if port_open "$addr"; then
        ok "a viewer is answering at $addr"
      else
        warn "nothing answers at $addr yet: on the PC, start glide-client.exe --listen and allow it"
        warn "through Windows Firewall. Glide keeps trying, so it connects once the viewer runs."
      fi
      VIEWER_HINT="glide-client.exe --listen" ;;
    listen)
      if [[ -n "$current" ]]; then
        plutil -remove connect "$cfg" >/dev/null 2>&1 && chmod 600 "$cfg"
        ok "the Mac no longer dials $current"
      fi
      ip="$(lan_address)"
      ok "the Mac listens on port $DEFAULT_PORT${ip:+ at $ip}"
      VIEWER_HINT="glide-client.exe ${ip:-MAC-ADDRESS}" ;;
    keep)
      ip="$(lan_address)"
      if [[ -n "$current" ]]; then VIEWER_HINT="glide-client.exe --listen"
      else VIEWER_HINT="glide-client.exe ${ip:-MAC-ADDRESS}"; fi ;;
  esac
}

HOST_STARTED=0
start_host() {
  step "Starting Glide Host"
  local i="" sock=""
  sock="$(config_dir)/control.sock"
  # "Quit & Reopen" in the Screen Recording prompt starts a host outside launchd, and only one
  # host may run.
  pkill -f "^$(printf '%s' "$APP" | sed 's/[][\.*^$+?(){}|]/\\&/g')/Contents/MacOS/glide-host\$" 2>/dev/null || true
  for i in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break
    if [[ $i == 5 ]]; then
      # For example over SSH, with nobody logged in at the Mac: it starts at the next login.
      warn "could not start it now (launchctl bootstrap failed); it starts at your next login"
      return 0
    fi
    sleep 1
  done
  HOST_STARTED=1
  for i in $(seq 1 50); do [[ -S "$sock" ]] && break; sleep 0.2; done
  if [[ -S "$sock" ]]; then
    ok "running (pid $(agent_pid "$LABEL")); the Glide icon is in the menu bar"
  else
    warn "started, but it isn't answering yet. Check ~/Library/Logs/glide-host.log"
  fi
}

pairing() {
  local bin="$APP/Contents/MacOS/glide-host"
  step "Pair the PC"
  if "$bin" --paired 2>/dev/null | grep -qv '^No paired viewers'; then
    ok "already paired:"
    "$bin" --paired 2>/dev/null | sed 's/^/      /'
    confirm "Pair another viewer now?" n || return 0
  else
    info "The PC has to be paired once: both screens show a 6-digit code and you confirm it."
    info "On the PC, start the viewer:  ${B}${VIEWER_HINT}${N}"
    info "${D}(Not set up yet? In PowerShell: irm https://raw.githubusercontent.com/$GLIDE_REPO/main/install.ps1 | iex)${N}"
    confirm "Open the pairing window now?" y || return 0
  fi
  "$bin" --pair </dev/tty || warn "not paired. Pair later from the menu bar: Glide → Pair New Viewer…"
}

summary() {
  printf '\n%s%sGlide Host %s is set up.%s\n' "$B" "$G" "$NEW_VERSION" "$N"
  info "App:      $APP"
  info "Log:      ~/Library/Logs/glide-host.log (menu bar → Open Log)"
  info "Settings: $(config_dir)/host.json"
  info "PC:       ${VIEWER_HINT:-glide-client.exe MAC-ADDRESS}"
  if [[ -n "$SELF_APP" ]]; then
    info "Run ${B}glide-setup${N} again to change the connection or pair another viewer."
  else
    info "Run this installer again to update, change the connection or pair another viewer."
  fi
}

uninstall() {
  local labels=() f="" l="" app=""
  if [[ -n "$OPT_LABEL" ]]; then
    labels=("$OPT_LABEL")
  else
    for f in "$HOME/Library/LaunchAgents/"*.glide.host.plist; do [[ -e "$f" ]] && labels+=("$(basename "$f" .plist)"); done
  fi
  [[ ${#labels[@]} -gt 0 ]] || labels=("$DEFAULT_LABEL")
  step "Uninstalling Glide Host"
  for l in "${labels[@]}"; do
    f="$HOME/Library/LaunchAgents/$l.plist"
    app="$(plutil -extract ProgramArguments.0 raw -o - "$f" 2>/dev/null || true)"
    app="${app%/Contents/MacOS/glide-host}"
    stop_agent "$l"
    rm -f "$f"
    ok "removed LaunchAgent $l"
    [[ -n "$app" ]] || app="${OPT_DIR:-$HOME/Applications}/Glide Host.app"
    if [[ -d "$app" ]]; then
      if [[ "$app" == "$SELF_APP" ]] || { command -v brew >/dev/null && brew list --cask glide-host >/dev/null 2>&1; }; then
        info "the app was installed with Homebrew: remove it with  brew uninstall --cask glide-host"
      else
        rm -rf "$app"; ok "removed $app"
      fi
    fi
    if [[ $OPT_PURGE == 1 ]]; then
      tccutil reset ScreenCapture "$l" >/dev/null 2>&1 || true
      tccutil reset Accessibility "$l" >/dev/null 2>&1 || true
    fi
  done
  if [[ $OPT_PURGE == 1 ]]; then
    rm -rf "$(config_dir)" "$HOME/Library/Logs/glide-host.log"
    ok "removed the settings, this Mac's key, the pairings, the log and the privacy grants"
  else
    info "kept the settings and pairings in $(config_dir) (--purge removes them)"
  fi
}

main() {
  parse_args "$@"
  if [[ $OPT_YES != 1 ]] && tty_ok; then INTERACTIVE=1; fi
  detect_self_app
  if [[ $OPT_UNINSTALL == 1 ]]; then uninstall; return; fi

  printf '%sGlide host setup%s %s(%s)%s\n' "$B" "$N" "$D" "$GLIDE_REPO" "$N"
  preflight
  obtain_app
  inspect_app
  remove_other_agents
  install_files
  VIEWER_HINT=""
  if [[ $INTERACTIVE == 1 ]]; then permissions; fi
  connection
  if [[ $OPT_NO_START == 1 ]]; then
    info "not started (--no-start). Start it with: launchctl bootstrap gui/$(id -u) \"$PLIST\""
    return
  fi
  start_host
  if [[ $INTERACTIVE == 1 && $HOST_STARTED == 1 ]]; then pairing; fi
  summary
}

main "$@"
