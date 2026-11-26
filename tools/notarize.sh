#!/bin/bash
# Notarizes and staples Mac release files with Apple's notary service (xcrun notarytool), using an
# App Store Connect API key. The release workflow runs it; it also works locally.
#
#   tools/notarize.sh FILE...
#
#   *.zip   a zip of one app (Glide Host.app or Glide Viewer.app, from tools/release.sh): submitted
#           as is, then the app is stapled and the zip rebuilt around the stapled app
#   *.dmg   a DMG signed with a Developer ID Application identity: submitted, then stapled
#   *.pkg   a pkg signed with a Developer ID Installer identity: submitted, then stapled
#
# Everything inside must already be signed with a Developer ID, the hardened runtime and a secure
# timestamp (GLIDE_HARDENED_RUNTIME=1, tools/mac-sign.sh); Apple rejects anything else.
#
# Environment (docs/RELEASING.md says how to get them):
#   APPLE_API_KEY_P8    the API key's .p8 file contents (-----BEGIN PRIVATE KEY----- …), or
#   APPLE_API_KEY_PATH  the path of that .p8 file
#   APPLE_API_KEY_ID    its Key ID (10 characters)
#   APPLE_API_ISSUER    the Issuer ID of the App Store Connect team (a UUID)
#   GLIDE_NOTARY_TIMEOUT  how long to wait for each submission (default 30m)
set -Eeuo pipefail

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

[[ "$(uname -s)" == Darwin ]] || die "notarization needs macOS (xcrun notarytool, stapler)"
[[ $# -gt 0 ]] || die "usage: tools/notarize.sh FILE.zip|FILE.dmg|FILE.pkg ..."
[[ -n "${APPLE_API_KEY_ID:-}" ]] || die "APPLE_API_KEY_ID is not set"
[[ -n "${APPLE_API_ISSUER:-}" ]] || die "APPLE_API_ISSUER is not set"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEY="${APPLE_API_KEY_PATH:-}"
if [[ -z "$KEY" ]]; then
  [[ -n "${APPLE_API_KEY_P8:-}" ]] || die "set APPLE_API_KEY_P8 (the .p8 contents) or APPLE_API_KEY_PATH"
  KEY="$WORK/AuthKey_$APPLE_API_KEY_ID.p8"
  ( umask 077; printf '%s\n' "$APPLE_API_KEY_P8" > "$KEY" )
fi
[[ -f "$KEY" ]] || die "no API key file at $KEY"
grep -q 'BEGIN PRIVATE KEY' "$KEY" || die "the API key is not a .p8 private key (PEM)"
AUTH=(--key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")

# submit FILE: upload, wait for the verdict, print Apple's log on anything but Accepted.
submit() {
  local file="$1" out="$WORK/submit.json" id="" status=""
  say "notarize: $(basename "$file")"
  if ! xcrun notarytool submit "$file" "${AUTH[@]}" --wait --timeout "${GLIDE_NOTARY_TIMEOUT:-30m}" \
      --output-format json > "$out"; then
    cat "$out" >&2 || true
  fi
  id="$(plutil -extract id raw -o - "$out" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$out" 2>/dev/null || true)"
  echo "submission ${id:-?}: ${status:-no status}"
  if [[ "$status" != Accepted ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${AUTH[@]}" >&2 || true
    die "$(basename "$file") was not notarized (${status:-submission failed})"
  fi
}

for f in "$@"; do
  [[ -f "$f" ]] || die "no such file: $f"
  case "$f" in
    *.zip)
      submit "$f"
      dir="$WORK/unzip"
      rm -rf "$dir" && mkdir -p "$dir"
      ditto -x -k "$f" "$dir"
      apps=("$dir"/*.app)
      [[ ${#apps[@]} -eq 1 && -d "${apps[0]}" ]] || die "$f must hold exactly one app"
      xcrun stapler staple "${apps[0]}"
      xcrun stapler validate "${apps[0]}"
      spctl --assess --type execute -vv "${apps[0]}"
      rm -f "$f"
      ditto -c -k --sequesterRsrc --keepParent "${apps[0]}" "$f"
      echo "stapled $(basename "${apps[0]}") in $f"
      ;;
    *.dmg|*.pkg)
      submit "$f"
      xcrun stapler staple "$f"
      xcrun stapler validate "$f"
      if [[ "$f" == *.pkg ]]; then
        spctl --assess --type install -vv "$f"
      else
        spctl --assess --type open --context context:primary-signature -vv "$f"
      fi
      echo "stapled $f"
      ;;
    *) die "$f: expected a .zip, .dmg or .pkg" ;;
  esac
done
