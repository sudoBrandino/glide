# Sourced by the packaging/deploy scripts. Defines the values that differ per developer.
# Put your own in .dev/build.env at the repo root (gitignored), or point GLIDE_BUILD_ENV at a
# file; variables already set in the environment win. Example .dev/build.env:
#
#   GLIDE_BUNDLE_ID="com.example.glide.host"
#   GLIDE_SIGN_ID="Apple Development: you@example.com (ABCDE12345)"
#   GLIDE_VIEWER_SSH="my-pc"
#
# shellcheck shell=bash
_glide_env_file="${GLIDE_BUILD_ENV:-$ROOT/.dev/build.env}"
if [[ -f "$_glide_env_file" ]]; then
  _glide_keep="$(export -p | grep -E '^declare -x GLIDE_' || true)"
  # shellcheck disable=SC1090
  source "$_glide_env_file"
  eval "$_glide_keep"   # the caller's environment wins over the file
fi
unset _glide_env_file _glide_keep

# Bundle identifier of Glide Host.app. It is also the LaunchAgent label and the code-signing
# identifier, so macOS privacy grants (Screen Recording, Accessibility) are tied to it.
GLIDE_BUNDLE_ID="${GLIDE_BUNDLE_ID:-io.github.sudobrandino.glide.host}"
# Code-signing identity ("security find-identity -v -p codesigning"). "-" = ad hoc: it works, but
# macOS may ask for the privacy grants again after each rebuild.
GLIDE_SIGN_ID="${GLIDE_SIGN_ID:--}"
