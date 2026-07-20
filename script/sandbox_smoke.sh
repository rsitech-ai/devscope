#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$("$ROOT_DIR/script/build_release_bundle.sh")"

"$ROOT_DIR/script/validate_release_bundle.sh" "$APP_BUNDLE"

osascript -e 'tell application "DevScope" to quit' >/dev/null 2>&1 || true
open -n "$APP_BUNDLE"
sleep 2
pgrep -x "DevScope" >/dev/null
osascript -e 'tell application "DevScope" to quit' >/dev/null 2>&1 || true

echo "Sandbox smoke passed: $APP_BUNDLE"
