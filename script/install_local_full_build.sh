#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist/local-full}"
APP_BUNDLE="$DIST_DIR/DevScope.app"
TARGET="${DEVSCOPE_INSTALL_TARGET:-/Applications/DevScope.app}"

DEVSCOPE_DIST_DIR="$DIST_DIR" \
DEVSCOPE_ENTITLEMENTS="$ROOT_DIR/config/DevScopeDeveloperID.entitlements" \
DEVSCOPE_REQUIRE_SANDBOX=0 \
"$ROOT_DIR/script/build_release_bundle.sh" >/dev/null

DEVSCOPE_REQUIRE_SANDBOX=0 \
DEVSCOPE_REQUIRE_APPLE_EVENTS=1 \
"$ROOT_DIR/script/validate_release_bundle.sh" "$APP_BUNDLE"

osascript -e 'tell application "DevScope" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x DevScope >/dev/null 2>&1 || true

if [[ -e "$TARGET" ]]; then
  mkdir -p "$HOME/.Trash"
  mv "$TARGET" "$HOME/.Trash/DevScope.app.$(date +%Y%m%d-%H%M%S)"
fi

ditto "$APP_BUNDLE" "$TARGET"
xattr -c "$TARGET" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$TARGET"
open -n "$TARGET"

cat <<SUMMARY
Installed full local DevScope build:
$TARGET

This install is intentionally not sandboxed. Use ./script/sandbox_smoke.sh
for App Store sandbox validation, not for the full local process-control app.
SUMMARY
