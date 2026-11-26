#!/bin/bash
# Fills in the MDM profile templates in packaging/mdm/ for a signed Glide Host release, ready to
# upload to Jamf, Intune or Kandji (packaging/mdm/README.md).
#
#   tools/fill-mdm-profiles.sh [options] GLIDE_HOST [OUTDIR]
#
# GLIDE_HOST is "Glide Host.app", the release's Glide-Host-*-macos-*.zip, or its .pkg. OUTDIR
# defaults to dist/mdm. What it does:
#   - glide-pppc.mobileconfig: the app's real designated requirement (codesign -dr -), which pins
#     its bundle id and your Developer ID team, in place of the TEAMID placeholder
#   - every profile: fresh PayloadUUIDs, PayloadOrganization, the app's bundle id
#   - glide-managed-preferences.mobileconfig and dev.brandino.glide.plist: the values below
#
# Options:
#   --cloud-url URL       CloudURL (https://…)
#   --token TOKEN         EnrollmentToken (from the admin console)
#   --device-name NAME    DeviceName (e.g. Jamf's $COMPUTERNAME); default: left empty
#   --tag TAG             a tag added at enrollment (repeat for several)
#   --disable-lan         DisableLANMode = true
#   --org NAME            PayloadOrganization (default: the name on the Developer ID certificate)
#   --allow-unsigned      accept an app that isn't signed with a Developer ID (testing only: the
#                         PPPC would then match only that exact build or certificate)
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$ROOT/packaging/mdm"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit "${1:-0}"; }

cloud_url="" token="" device_name="" org="" disable_lan=0 allow_unsigned=0 tags=() args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud-url) cloud_url="${2:?--cloud-url needs a value}"; shift 2 ;;
    --token) token="${2:?--token needs a value}"; shift 2 ;;
    --device-name) device_name="${2:?--device-name needs a value}"; shift 2 ;;
    --tag) tags+=("${2:?--tag needs a value}"); shift 2 ;;
    --disable-lan) disable_lan=1; shift ;;
    --org) org="${2:?--org needs a value}"; shift 2 ;;
    --allow-unsigned) allow_unsigned=1; shift ;;
    -h|--help) usage 0 ;;
    -*) die "unknown option $1 (try --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -ge 1 && ${#args[@]} -le 2 ]] || usage 2
[[ "$(uname -s)" == Darwin ]] || die "needs macOS (codesign, plutil)"
input="${args[0]}"
out="${args[1]:-$ROOT/dist/mdm}"
if [[ -n "$cloud_url" && "$cloud_url" != https://* ]]; then die "--cloud-url must start with https://"; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Find the app.
case "$input" in
  *.app|*.app/) app="${input%/}" ;;
  *.zip)
    ditto -x -k "$input" "$work/zip"
    app="$(find "$work/zip" -maxdepth 1 -name '*.app' -type d | head -1)" ;;
  *.pkg)
    pkgutil --expand-full "$input" "$work/pkg" >/dev/null
    app="$(find "$work/pkg" -path '*/Payload/Applications/*.app' -maxdepth 4 -type d | head -1)" ;;
  *) die "$input: expected Glide Host.app, a .zip or a .pkg" ;;
esac
[[ -n "${app:-}" && -d "$app" ]] || die "no app found in $input"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[[ "$bundle_id" == *.host ]] || die "$app is $bundle_id, not Glide Host (the PPPC profile is for the host)"

# Its signature.
codesign --verify --strict "$app" || die "$app has a broken signature"
requirement="$(codesign -dr - "$app" 2>/dev/null | sed -n 's/^\(# \)\{0,1\}designated => //p')"
[[ -n "$requirement" ]] || die "could not read the designated requirement of $app"
info="$(codesign -dv --verbose=2 "$app" 2>&1)"
team="$(sed -n 's/^TeamIdentifier=//p' <<<"$info")"
authority="$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"$info" | head -1)"
if [[ -z "$authority" || -z "$team" || "$team" == "not set" || "$requirement" != *"anchor apple generic"* ]]; then
  [[ $allow_unsigned == 1 ]] || die "$app is not signed with a Developer ID (requirement: $requirement).
       MDM profiles need a release signed by the project's Developer ID; --allow-unsigned overrides."
  echo "warning: not a Developer ID signature; the PPPC profile matches only: $requirement" >&2
fi
if [[ -z "$org" ]]; then
  org="$(sed -n 's/^Developer ID Application: \(.*\) ([A-Z0-9]*)$/\1/p' <<<"$authority")"
  org="${org:-Glide}"
fi

mkdir -p "$out"
set_string() { plutil -replace "$2" -string "$3" "$1"; }

# Fresh UUIDs for the profile and each payload, and the organization.
finish_profile() {
  local f="$1" i=0
  set_string "$f" PayloadUUID "$(uuidgen)"
  set_string "$f" PayloadOrganization "$org"
  while plutil -extract "PayloadContent.$i" xml1 -o /dev/null "$f" 2>/dev/null; do
    set_string "$f" "PayloadContent.$i.PayloadUUID" "$(uuidgen)"
    i=$((i + 1))
  done
}

# PPPC.
pppc="$out/glide-pppc.mobileconfig"
cp "$TEMPLATES/glide-pppc.mobileconfig" "$pppc"
for svc in Accessibility ScreenCapture; do
  set_string "$pppc" "PayloadContent.0.Services.$svc.0.CodeRequirement" "$requirement"
  set_string "$pppc" "PayloadContent.0.Services.$svc.0.Identifier" "$bundle_id"
done
finish_profile "$pppc"

# Managed login items.
login="$out/glide-login-items.mobileconfig"
cp "$TEMPLATES/glide-login-items.mobileconfig" "$login"
set_string "$login" PayloadContent.0.Rules.0.RuleValue "$bundle_id"
set_string "$login" PayloadContent.0.Rules.1.RuleValue "$bundle_id"
finish_profile "$login"

# Managed preferences: the same values in the profile (under PayloadContent.0) and the plain plist.
prefs="$out/glide-managed-preferences.mobileconfig"
plain="$out/dev.brandino.glide.plist"
cp "$TEMPLATES/glide-managed-preferences.mobileconfig" "$prefs"
cp "$TEMPLATES/dev.brandino.glide.plist" "$plain"
fill_prefs() {
  local f="$1" p="$2" i=0 t=""
  [[ -n "$cloud_url" ]] && set_string "$f" "${p}CloudURL" "$cloud_url"
  [[ -n "$token" ]] && set_string "$f" "${p}EnrollmentToken" "$token"
  [[ -n "$device_name" ]] && set_string "$f" "${p}DeviceName" "$device_name"
  if [[ ${#tags[@]} -gt 0 ]]; then
    plutil -replace "${p}Tags" -array "$f"
    for t in "${tags[@]}"; do plutil -insert "${p}Tags.$i" -string "$t" "$f"; i=$((i + 1)); done
  fi
  [[ $disable_lan == 1 ]] && plutil -replace "${p}DisableLANMode" -bool YES "$f"
  return 0
}
fill_prefs "$prefs" PayloadContent.0.
fill_prefs "$plain" ""
finish_profile "$prefs"

for f in "$pppc" "$login" "$prefs" "$plain"; do
  plutil -lint -s "$f" || die "$f is not a valid plist"
done
grep -q TEAMID "$pppc" && die "$pppc still names the TEAMID placeholder"
if grep -qE 'glide\.example\.com|ENROLLMENT_TOKEN' "$prefs"; then
  echo "note: the managed preferences still hold the placeholders; pass --cloud-url and --token" >&2
fi

echo "bundle id:   $bundle_id"
echo "team:        ${team:-none}"
echo "requirement: $requirement"
echo "wrote $pppc"
echo "wrote $login"
echo "wrote $prefs"
echo "wrote $plain"
[[ -z "$token" ]] || echo "note: $prefs and $plain contain the enrollment token; treat them as secrets" >&2
