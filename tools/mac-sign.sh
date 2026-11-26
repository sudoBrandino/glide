# Code signing for the Mac app bundles, sourced by tools/make-host-app.sh and
# tools/make-viewer-app.sh (after tools/build-env.sh). Environment:
#   GLIDE_SIGN_ID            identity name or SHA-1, or "-" for ad hoc (tools/build-env.sh)
#   GLIDE_HARDENED_RUNTIME=1 hardened runtime + secure timestamp, as notarization requires (needs a
#                            Developer ID GLIDE_SIGN_ID)
#   GLIDE_SIGN_KEYCHAIN      a keychain that holds the identity (e.g. the release workflow's
#                            temporary one, or the self-signed "Glide Release Signing" certificate),
#                            unlocked with the password in GLIDE_SIGN_KEYCHAIN_PASSWORD_FILE if set
# shellcheck shell=bash

# glide_find_identity KEYCHAIN NAME-OR-SHA1 [POLICY]: the identity's SHA-1, or nothing. Signing by
# SHA-1 rather than by name: a self-signed certificate isn't trusted, and codesign's lookup by
# name doesn't find untrusted identities on every macOS version. POLICY "codesigning" (default)
# for apps; "basic" lists Developer ID Installer identities too.
glide_find_identity() {
  local kc="$1" want="$2" policy="${3:-codesigning}"
  security find-identity -p "$policy" "$kc" \
    | awk -v name="\"$want\"" -v id="$(printf '%s' "$want" | tr '[:lower:]' '[:upper:]')" \
        'index($0, name) || toupper($2) == id { print $2; exit }'
}

# glide_sign_app PATH IDENTIFIER [ENTITLEMENTS]: sign PATH (an app or a bare executable) and print
# its designated requirement. Sign nested code first: the outer signature seals it.
glide_sign_app() {
  local app="$1" ident="$2" ent="${3:-}" id="$GLIDE_SIGN_ID" hash=""
  local flags=(--timestamp=none)
  [[ "${GLIDE_HARDENED_RUNTIME:-0}" == 1 ]] && flags=(--options runtime --timestamp)
  [[ -n "$ent" ]] && flags+=(--entitlements "$ent")
  if [[ -n "${GLIDE_SIGN_KEYCHAIN:-}" ]]; then
    [[ -f "$GLIDE_SIGN_KEYCHAIN" ]] || { echo "GLIDE_SIGN_KEYCHAIN: no such keychain: $GLIDE_SIGN_KEYCHAIN" >&2; return 1; }
    if [[ -n "${GLIDE_SIGN_KEYCHAIN_PASSWORD_FILE:-}" ]]; then
      security unlock-keychain -p "$(cat "$GLIDE_SIGN_KEYCHAIN_PASSWORD_FILE")" "$GLIDE_SIGN_KEYCHAIN"
    fi
    flags+=(--keychain "$GLIDE_SIGN_KEYCHAIN")
    hash="$(glide_find_identity "$GLIDE_SIGN_KEYCHAIN" "$id")"
    if [[ -z "$hash" ]]; then
      echo "no signing identity \"$id\" in $GLIDE_SIGN_KEYCHAIN; it holds:" >&2
      security find-identity -p codesigning "$GLIDE_SIGN_KEYCHAIN" >&2
      return 1
    fi
    id="$hash"
  fi
  codesign --force "${flags[@]}" --sign "$id" --identifier "$ident" "$app"
  codesign --verify --strict --verbose=1 "$app" 2>&1 | tail -1
  codesign -dr - "$app" 2>&1 | grep designated
}
