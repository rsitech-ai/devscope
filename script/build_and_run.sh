#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="DevScope"
BUNDLE_ID="dev.andrzej.DevScope"
MIN_SYSTEM_VERSION="14.0"
MARKETING_VERSION="${DEVSCOPE_MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${DEVSCOPE_BUILD_VERSION:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

swift "$ROOT_DIR/script/generate_app_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_RESOURCES/PrivacyInfo.xcprivacy"

plutil -create xml1 "$INFO_PLIST"
plutil -insert CFBundleExecutable -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$INFO_PLIST"
plutil -insert CFBundleName -string "$APP_NAME" "$INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$INFO_PLIST"
plutil -insert CFBundleVersion -string "$BUILD_VERSION" "$INFO_PLIST"
plutil -insert LSApplicationCategoryType -string "public.app-category.developer-tools" "$INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$INFO_PLIST"
plutil -insert NSAppleEventsUsageDescription -string \
  "DevScope uses System Events only to inspect and manage current-user legacy login items you explicitly choose." \
  "$INFO_PLIST"
plutil -insert NSHumanReadableCopyright -string \
  "Copyright © 2026 Rafal Sikora." "$INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool true "$INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$INFO_PLIST"

# SwiftPM signs the standalone development executable. Re-sign the completed
# bundle so its Info.plist and resources are covered by a coherent signature.
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n -a "$APP_BUNDLE"
}

verify_exact_app() {
  local attempt pid running_command

  for ((attempt = 0; attempt < 30; attempt++)); do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      running_command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
      running_command="${running_command#"${running_command%%[![:space:]]*}"}"
      if [[ "$running_command" == "$APP_BINARY" ]]; then
        return 0
      fi
    done < <(/usr/bin/pgrep -x "$APP_NAME" || true)
    sleep 0.1
  done

  echo "error: exact built app did not launch: $APP_BINARY" >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_exact_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
