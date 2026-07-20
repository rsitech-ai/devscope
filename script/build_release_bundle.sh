#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DevScope"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist}"
RELEASE_BUILD_ROOT="${DEVSCOPE_RELEASE_BUILD_ROOT:-$ROOT_DIR/.build/release-bundles}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET_DIR="$RELEASE_BUILD_ROOT/AppIcon.iconset"

BUNDLE_ID="${DEVSCOPE_BUNDLE_ID:-com.s1korrrr.DevScope}"
MIN_SYSTEM_VERSION="${DEVSCOPE_MIN_SYSTEM_VERSION:-14.0}"
MARKETING_VERSION="${DEVSCOPE_MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${DEVSCOPE_BUILD_VERSION:-1}"
COPYRIGHT="${DEVSCOPE_COPYRIGHT:-Copyright © 2026 Rafal Sikora.}"
SIGN_IDENTITY="${DEVSCOPE_SIGN_IDENTITY:--}"
ENTITLEMENTS="${DEVSCOPE_ENTITLEMENTS:-$ROOT_DIR/config/DevScope.entitlements}"
PROVISIONING_PROFILE="${DEVSCOPE_PROVISIONING_PROFILE:-}"
HARDENED_RUNTIME="${DEVSCOPE_HARDENED_RUNTIME:-0}"
ARCHITECTURES="${DEVSCOPE_ARCHITECTURES:-arm64 x86_64}"

cd "$ROOT_DIR"

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: entitlements file not found: $ENTITLEMENTS" >&2
  exit 2
fi

BUILD_BINARIES=()
for architecture in $ARCHITECTURES; do
  scratchPath="$RELEASE_BUILD_ROOT/$architecture"
  BUILD_ARGS=(
    -c release
    --arch "$architecture"
    --build-system native
    --scratch-path "$scratchPath"
  )
  swift build "${BUILD_ARGS[@]}" >&2
  BUILD_BINARY="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
  if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "error: release binary not found for $architecture: $BUILD_BINARY" >&2
    exit 2
  fi
  BUILD_BINARIES+=("$BUILD_BINARY")
done

rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
/usr/bin/lipo -create "${BUILD_BINARIES[@]}" -output "$APP_BINARY"
for architecture in $ARCHITECTURES; do
  /usr/bin/lipo "$APP_BINARY" -verify_arch "$architecture"
done
chmod +x "$APP_BINARY"

swift "$ROOT_DIR/script/generate_app_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$ROOT_DIR/Resources/AppIcon.svg" "$APP_RESOURCES/AppIcon.svg"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/LICENSE"
cp "$ROOT_DIR/NOTICE" "$APP_RESOURCES/NOTICE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"

if [[ -n "$PROVISIONING_PROFILE" ]]; then
  if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "error: provisioning profile not found: $PROVISIONING_PROFILE" >&2
    exit 2
  fi
  cp "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"
fi

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleDevelopmentRegion -string "en" "$INFO_PLIST"
plutil -insert CFBundleDisplayName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$BUILD_VERSION" "$INFO_PLIST"
plutil -insert LSApplicationCategoryType -string "public.app-category.developer-tools" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
plutil -insert NSApplicationSupportsSecureRestorableState -bool true "$INFO_PLIST"
plutil -insert NSAppleEventsUsageDescription -string \
  "DevScope uses System Events only to inspect and manage current-user legacy login items you explicitly choose." \
  "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
plutil -insert NSHumanReadableCopyright -string "$COPYRIGHT" "$INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$INFO_PLIST"
plutil -insert NSSupportsAutomaticTermination -bool true "$INFO_PLIST"
plutil -insert NSSupportsSuddenTermination -bool true "$INFO_PLIST"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS")
if [[ "$HARDENED_RUNTIME" == "1" ]]; then
  SIGN_ARGS+=(--options runtime)
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
else
  SIGN_ARGS+=(--timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE" >&2
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE" >&2

echo "$APP_BUNDLE"
