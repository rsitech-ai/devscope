#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist/app-store}"
APP_BUNDLE="$DIST_DIR/DevScope.app"
PKG_PATH="$DIST_DIR/DevScope.pkg"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
PROFILE_PLIST="$TMP_DIR/profile.plist"
APP_STORE_ENTITLEMENTS="$TMP_DIR/DevScopeAppStore.entitlements"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: $name is required" >&2
    exit 2
  fi
}

require_env DEVSCOPE_BUNDLE_ID
require_env DEVSCOPE_MARKETING_VERSION
require_env DEVSCOPE_BUILD_VERSION
require_env DEVSCOPE_APP_STORE_SIGN_IDENTITY
require_env DEVSCOPE_INSTALLER_IDENTITY
require_env DEVSCOPE_PROVISIONING_PROFILE

if ! security find-identity -p codesigning -v | grep -F "$DEVSCOPE_APP_STORE_SIGN_IDENTITY" >/dev/null; then
  echo "error: App Store application signing identity not found: $DEVSCOPE_APP_STORE_SIGN_IDENTITY" >&2
  security find-identity -p codesigning -v >&2
  exit 2
fi

if ! security find-identity -v | grep -F "$DEVSCOPE_INSTALLER_IDENTITY" >/dev/null; then
  echo "error: App Store installer signing identity not found: $DEVSCOPE_INSTALLER_IDENTITY" >&2
  security find-identity -v >&2
  exit 2
fi

mkdir -p "$DIST_DIR"

security cms -D -i "$DEVSCOPE_PROVISIONING_PROFILE" -o "$PROFILE_PLIST" >/dev/null \
  || { echo "error: provisioning profile could not be decoded" >&2; exit 2; }
PROFILE_TEAM="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")"
PROFILE_PREFIX="$(plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$PROFILE_PLIST")"
PROFILE_APP_ID="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$PROFILE_PLIST")"
if [[ "$PROFILE_APP_ID" != "$PROFILE_PREFIX.$DEVSCOPE_BUNDLE_ID" ]]; then
  echo "error: provisioning profile application identifier does not match DEVSCOPE_BUNDLE_ID" >&2
  exit 2
fi

cp "$ROOT_DIR/config/DevScope.entitlements" "$APP_STORE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$APP_STORE_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $PROFILE_TEAM" "$APP_STORE_ENTITLEMENTS"

DEVSCOPE_DIST_DIR="$DIST_DIR" \
DEVSCOPE_SIGN_IDENTITY="$DEVSCOPE_APP_STORE_SIGN_IDENTITY" \
DEVSCOPE_ENTITLEMENTS="$APP_STORE_ENTITLEMENTS" \
DEVSCOPE_PROVISIONING_PROFILE="$DEVSCOPE_PROVISIONING_PROFILE" \
"$ROOT_DIR/script/build_release_bundle.sh" >/dev/null

DEVSCOPE_REQUIRE_SANDBOX=1 \
DEVSCOPE_REQUIRE_PROVISIONING_PROFILE=1 \
"$ROOT_DIR/script/validate_release_bundle.sh" "$APP_BUNDLE"

rm -f "$PKG_PATH"
productbuild --component "$APP_BUNDLE" /Applications --sign "$DEVSCOPE_INSTALLER_IDENTITY" "$PKG_PATH"
pkgutil --check-signature "$PKG_PATH"

cat <<SUMMARY
Created App Store package:
$PKG_PATH

Upload this package with Apple Transporter or App Store Connect tooling, then complete App Review metadata and notes.
SUMMARY
