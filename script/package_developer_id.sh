#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist/developer-id}"
APP_BUNDLE="$DIST_DIR/DevScope.app"
ZIP_PATH="$DIST_DIR/DevScope.zip"
NOTARY_PROFILE="${DEVSCOPE_NOTARY_KEYCHAIN_PROFILE:-}"
ALLOW_UNNOTARIZED="${DEVSCOPE_ALLOW_UNNOTARIZED:-0}"

if [[ -z "${DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY:-}" ]]; then
  echo "error: DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY is required" >&2
  exit 2
fi

if ! security find-identity -p codesigning -v | grep -F "$DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY" >/dev/null; then
  echo "error: Developer ID signing identity not found: $DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY" >&2
  security find-identity -p codesigning -v >&2
  exit 2
fi

if [[ -z "$NOTARY_PROFILE" && "$ALLOW_UNNOTARIZED" != "1" ]]; then
  echo "error: notary profile is required for a release artifact; set DEVSCOPE_ALLOW_UNNOTARIZED=1 only for local development" >&2
  exit 2
fi

mkdir -p "$DIST_DIR"

DEVSCOPE_DIST_DIR="$DIST_DIR" \
DEVSCOPE_SIGN_IDENTITY="$DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY" \
DEVSCOPE_ENTITLEMENTS="$ROOT_DIR/config/DevScopeDeveloperID.entitlements" \
DEVSCOPE_HARDENED_RUNTIME=1 \
"$ROOT_DIR/script/build_release_bundle.sh" >/dev/null

DEVSCOPE_REQUIRE_SANDBOX=0 \
DEVSCOPE_REQUIRE_APPLE_EVENTS=1 \
"$ROOT_DIR/script/validate_release_bundle.sh" "$APP_BUNDLE"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ZIP_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  spctl -a -t exec -vv "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent --norsrc --noextattr "$APP_BUNDLE" "$ZIP_PATH"
else
  cat <<NOTE
Created development-only signed but unnotarized archive:
$ZIP_PATH

DEVSCOPE_ALLOW_UNNOTARIZED=1 was explicitly set; do not distribute this artifact.
NOTE
fi

echo "$ZIP_PATH"
