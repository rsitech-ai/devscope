#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${1:-$ROOT_DIR/dist/DevScope.app}"
APP_NAME="$(basename "$APP_BUNDLE" .app)"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
APP_RESOURCES="$APP_CONTENTS/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "app bundle not found: $APP_BUNDLE"
[[ -x "$APP_BINARY" ]] || fail "main executable missing or not executable: $APP_BINARY"
[[ -f "$APP_CONTENTS/Info.plist" ]] || fail "Info.plist missing"
[[ -f "$APP_RESOURCES/AppIcon.icns" ]] || fail "AppIcon.icns missing"
[[ -f "$APP_RESOURCES/PrivacyInfo.xcprivacy" ]] || fail "PrivacyInfo.xcprivacy missing"
for notice in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  [[ -s "$APP_RESOURCES/$notice" ]] || fail "$notice missing or empty"
done

plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null
plutil -lint "$APP_RESOURCES/PrivacyInfo.xcprivacy" >/dev/null

if [[ "${DEVSCOPE_REQUIRE_PRIVACY_MANIFEST:-1}" == "1" ]]; then
  PRIVACY_MANIFEST="$(plutil -convert xml1 -o - "$APP_RESOURCES/PrivacyInfo.xcprivacy")"
  if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" <<<"$PRIVACY_MANIFEST"; then
    fail "PrivacyInfo.xcprivacy missing UserDefaults required-reason API declaration"
  fi

  if ! grep -q "CA92.1" <<<"$PRIVACY_MANIFEST"; then
    fail "PrivacyInfo.xcprivacy missing UserDefaults reason CA92.1"
  fi
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_CONTENTS/Info.plist")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_CONTENTS/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_CONTENTS/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP_BINARY")"

[[ -n "$BUNDLE_ID" ]] || fail "CFBundleIdentifier is empty"
[[ -n "$VERSION" ]] || fail "CFBundleShortVersionString is empty"
[[ -n "$BUILD" ]] || fail "CFBundleVersion is empty"

for requiredArchitecture in ${DEVSCOPE_REQUIRED_ARCHITECTURES-arm64 x86_64}; do
  if [[ " $ARCHITECTURES " != *" $requiredArchitecture "* ]]; then
    fail "required architecture missing: $requiredArchitecture (found: $ARCHITECTURES)"
  fi
done

codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
codesign -dvvv --xml --entitlements - "$APP_BUNDLE" >"$TMP_DIR/entitlements.txt" 2>"$TMP_DIR/codesign.txt"

if [[ "${DEVSCOPE_REQUIRE_SANDBOX:-1}" == "1" ]]; then
  if ! SANDBOX_VALUE="$(
    plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$TMP_DIR/entitlements.txt" 2>/dev/null
  )"; then
    cat "$TMP_DIR/entitlements.txt" >&2
    fail "App Sandbox entitlement missing"
  fi

  if [[ "$SANDBOX_VALUE" != "true" ]]; then
    cat "$TMP_DIR/entitlements.txt" >&2
    fail "App Sandbox entitlement is not true"
  fi

  if ! USER_SELECTED_READ_WRITE_VALUE="$(
    plutil -extract 'com\.apple\.security\.files\.user-selected\.read-write' raw -o - \
      "$TMP_DIR/entitlements.txt" 2>/dev/null
  )"; then
    cat "$TMP_DIR/entitlements.txt" >&2
    fail "user-selected read-write entitlement missing for sandbox file import/export"
  fi
  if [[ "$USER_SELECTED_READ_WRITE_VALUE" != "true" ]]; then
    cat "$TMP_DIR/entitlements.txt" >&2
    fail "user-selected read-write entitlement is not true"
  fi
elif grep -q "com.apple.security.app-sandbox" "$TMP_DIR/entitlements.txt"; then
  cat "$TMP_DIR/entitlements.txt" >&2
  fail "App Sandbox entitlement must be absent for the full process-control build"
fi

if [[ "${DEVSCOPE_REQUIRE_APPLE_EVENTS:-0}" == "1" ]]; then
  if ! APPLE_EVENTS_VALUE="$(
    plutil -extract 'com\.apple\.security\.automation\.apple-events' raw -o - \
      "$TMP_DIR/entitlements.txt" 2>/dev/null
  )"; then
    cat "$TMP_DIR/entitlements.txt" >&2
    fail "Apple Events entitlement missing for legacy login-item integration"
  fi
  [[ "$APPLE_EVENTS_VALUE" == "true" ]] \
    || fail "Apple Events entitlement is not true"
  APPLE_EVENTS_USAGE="$(
    plutil -extract NSAppleEventsUsageDescription raw -o - "$APP_CONTENTS/Info.plist" 2>/dev/null
  )" || fail "NSAppleEventsUsageDescription missing"
  [[ -n "$APPLE_EVENTS_USAGE" ]] || fail "NSAppleEventsUsageDescription is empty"
fi

if [[ "${DEVSCOPE_REQUIRE_PROVISIONING_PROFILE:-0}" == "1" ]]; then
  PROFILE="$APP_CONTENTS/embedded.provisionprofile"
  PROFILE_PLIST="$TMP_DIR/profile.plist"
  [[ -f "$PROFILE" ]] || fail "embedded.provisionprofile missing"
  security cms -D -i "$PROFILE" -o "$PROFILE_PLIST" >/dev/null \
    || fail "embedded.provisionprofile could not be decoded"
  plutil -lint "$PROFILE_PLIST" >/dev/null \
    || fail "embedded.provisionprofile payload is invalid"

  PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
  PROFILE_EXPIRATION_EPOCH="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" +%s 2>/dev/null)" \
    || fail "embedded.provisionprofile ExpirationDate is invalid"
  [[ "$PROFILE_EXPIRATION_EPOCH" -gt "$(date -u +%s)" ]] \
    || fail "embedded.provisionprofile is expired"

  PROFILE_TEAM="$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")"
  PROFILE_PREFIX="$(plutil -extract ApplicationIdentifierPrefix.0 raw -o - "$PROFILE_PLIST")"
  PROFILE_APP_ID="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$PROFILE_PLIST")"
  PROFILE_SANDBOX="$(plutil -extract 'Entitlements.com\.apple\.security\.app-sandbox' raw -o - "$PROFILE_PLIST")"
  APP_TEAM="$(plutil -extract 'com\.apple\.developer\.team-identifier' raw -o - "$TMP_DIR/entitlements.txt")"
  APP_ID="$(plutil -extract 'com\.apple\.application-identifier' raw -o - "$TMP_DIR/entitlements.txt")"

  [[ "$PROFILE_APP_ID" == "$PROFILE_PREFIX.$BUNDLE_ID" ]] \
    || fail "embedded.provisionprofile application-identifier does not match bundle ID"
  [[ "$APP_ID" == "$PROFILE_APP_ID" ]] \
    || fail "signed application-identifier does not match embedded.provisionprofile"
  [[ "$APP_TEAM" == "$PROFILE_TEAM" ]] \
    || fail "signed TeamIdentifier does not match embedded.provisionprofile"
  [[ "$PROFILE_SANDBOX" == "true" ]] \
    || fail "embedded profile App Sandbox entitlement is not true"

  codesign -d --extract-certificates "$TMP_DIR/app-signing-cert" "$APP_BUNDLE" 2>/dev/null \
    || fail "app signing certificate could not be extracted"
  PROFILE_CERTIFICATE_MATCH=0
  PROFILE_CERTIFICATE_INDEX=0
  while PROFILE_CERTIFICATE="$({
    plutil -extract "DeveloperCertificates.$PROFILE_CERTIFICATE_INDEX" raw -o - "$PROFILE_PLIST"
  } 2>/dev/null)"; do
    printf '%s' "$PROFILE_CERTIFICATE" | base64 -D >"$TMP_DIR/profile-cert" \
      || fail "embedded.provisionprofile contains an invalid developer certificate"
    if cmp -s "$TMP_DIR/app-signing-cert0" "$TMP_DIR/profile-cert"; then
      PROFILE_CERTIFICATE_MATCH=1
      break
    fi
    PROFILE_CERTIFICATE_INDEX=$((PROFILE_CERTIFICATE_INDEX + 1))
  done
  [[ "$PROFILE_CERTIFICATE_MATCH" == "1" ]] \
    || fail "app signing certificate is not authorized by embedded.provisionprofile"
fi

if [[ "${DEVSCOPE_REQUIRE_GATEKEEPER:-0}" == "1" ]]; then
  spctl -a -t exec -vv "$APP_BUNDLE"
else
  spctl -a -t exec -vv "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

cat <<SUMMARY
Validated $APP_BUNDLE
Bundle ID: $BUNDLE_ID
Version: $VERSION ($BUILD)
Architectures: $ARCHITECTURES
Sandbox requirement: ${DEVSCOPE_REQUIRE_SANDBOX:-1}
SUMMARY
