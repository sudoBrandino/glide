#!/bin/bash
# Installs the locally built dist/Glide Host.app (tools/make-host-app.sh) to ~/Applications with
# its per-user LaunchAgent, and (re)starts it. A thin, non-interactive wrapper around the
# installer at the repository root (install.sh); run that one directly for the guided setup
# (permissions, connection, pairing). No sudo needed.
#   install-host.sh            install/update app + agent, (re)start it
#   install-host.sh --no-start install/update only
#   install-host.sh --uninstall
# Extra options are passed on to install.sh (for example --replace-other; see install.sh --help).
# The LaunchAgent label is the app's bundle identifier (GLIDE_BUNDLE_ID, see tools/build-env.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/build-env.sh
source "$ROOT/tools/build-env.sh"

if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  exec "$ROOT/install.sh" --uninstall --label "$GLIDE_BUNDLE_ID" "$@"
fi
[[ -d "$ROOT/dist/Glide Host.app" ]] || { echo "no dist/Glide Host.app: run tools/make-host-app.sh first" >&2; exit 1; }
exec "$ROOT/install.sh" --yes --app "$ROOT/dist/Glide Host.app" "$@"
