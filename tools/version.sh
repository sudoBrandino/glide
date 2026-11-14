#!/bin/bash
# Glide's version lives in the VERSION file at the repo root. Two places can't read it at build
# time and carry a copy: windows/Cargo.toml (+ Cargo.lock) and mac/Sources/GlideCore/Version.swift.
#   tools/version.sh              print the version
#   tools/version.sh check        fail if any copy differs from VERSION (CI, tools/release.sh)
#   tools/version.sh set X.Y.Z    write X.Y.Z to VERSION and every copy
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
CARGO_TOML="$ROOT/windows/Cargo.toml"
CARGO_LOCK="$ROOT/windows/Cargo.lock"
SWIFT="$ROOT/mac/Sources/GlideCore/Version.swift"
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

cargo_version() { sed -nE '/^\[package\]/,/^\[/{s/^version = "([^"]+)"/\1/p;}' "$CARGO_TOML" | head -1; }
lock_version() { awk '/^name = "glide-client"$/{getline; gsub(/version = |"/, ""); print; exit}' "$CARGO_LOCK"; }
swift_version() { sed -nE 's/^ *public static let version = "([^"]+)"/\1/p' "$SWIFT" | head -1; }

read_version() {
  local v
  v="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
  [[ "$v" =~ $SEMVER ]] || { echo "VERSION: '$v' is not semver (X.Y.Z or X.Y.Z-pre)" >&2; exit 1; }
  printf '%s' "$v"
}

case "${1:-}" in
  "")
    read_version; echo ;;
  check)
    v="$(read_version)"; bad=0
    for pair in "windows/Cargo.toml:$(cargo_version)" "windows/Cargo.lock:$(lock_version)" \
                "mac/Sources/GlideCore/Version.swift:$(swift_version)"; do
      if [[ "${pair#*:}" != "$v" ]]; then
        echo "version mismatch: ${pair%%:*} has '${pair#*:}', VERSION has '$v' (run tools/version.sh set $v)" >&2
        bad=1
      fi
    done
    [[ $bad == 0 ]] && echo "version $v: VERSION, Cargo.toml, Cargo.lock and Version.swift agree"
    exit $bad ;;
  set)
    new="${2:-}"
    [[ "$new" =~ $SEMVER ]] || { echo "usage: tools/version.sh set X.Y.Z[-pre]" >&2; exit 2; }
    printf '%s\n' "$new" > "$VERSION_FILE"
    # Portable in-place edits (BSD and GNU sed differ on -i).
    tmp="$(mktemp)"
    awk -v v="$new" '/^\[package\]/{p=1} /^\[/&&!/^\[package\]/{p=0} p&&/^version = /&&!d{print "version = \"" v "\""; d=1; next} {print}' "$CARGO_TOML" > "$tmp" && cat "$tmp" > "$CARGO_TOML"
    awk -v v="$new" '/^name = "glide-client"$/{print; getline; print "version = \"" v "\""; next} {print}' "$CARGO_LOCK" > "$tmp" && cat "$tmp" > "$CARGO_LOCK"
    sed -E "s/^( *public static let version = )\"[^\"]+\"/\1\"$new\"/" "$SWIFT" > "$tmp" && cat "$tmp" > "$SWIFT"
    rm -f "$tmp"
    "$0" check ;;
  *)
    echo "usage: tools/version.sh [check | set X.Y.Z]" >&2; exit 2 ;;
esac
