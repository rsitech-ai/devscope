#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DEVSCOPE_DIST_DIR:-$ROOT_DIR/dist/community-preview}"
MARKETING_VERSION="${DEVSCOPE_MARKETING_VERSION:-0.1.0}"
PREVIEW_LABEL="${DEVSCOPE_PREVIEW_LABEL:-preview.1}"
ACKNOWLEDGEMENT="${DEVSCOPE_ACKNOWLEDGE_UNNOTARIZED_PREVIEW:-0}"

if [[ "$ACKNOWLEDGEMENT" != "1" ]]; then
  cat >&2 <<'ERROR'
error: community preview packaging requires explicit acknowledgement

Set DEVSCOPE_ACKNOWLEDGE_UNNOTARIZED_PREVIEW=1 only when publishing a clearly
labeled, ad-hoc signed and unnotarized prerelease. This is not a production
Developer ID distribution artifact.
ERROR
  exit 2
fi

if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "error: invalid DEVSCOPE_MARKETING_VERSION: $MARKETING_VERSION" >&2
  exit 2
fi

if [[ ! "$PREVIEW_LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "error: invalid DEVSCOPE_PREVIEW_LABEL: $PREVIEW_LABEL" >&2
  exit 2
fi

SOURCE_COMMIT="${DEVSCOPE_SOURCE_COMMIT:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: DEVSCOPE_SOURCE_COMMIT must be a full 40-character Git SHA" >&2
  exit 2
fi

mkdir -p "$DIST_DIR"
TEMP_ROOT="$(mktemp -d "$DIST_DIR/.community-preview.XXXXXX")"
cleanup() {
  if [[ -d "$TEMP_ROOT" ]]; then
    find "$TEMP_ROOT" -depth -delete
  fi
}
trap cleanup EXIT

PACKAGE_NAME="DevScope-$MARKETING_VERSION-$PREVIEW_LABEL-macos-universal"
PACKAGE_ROOT="$TEMP_ROOT/$PACKAGE_NAME"
APP_BUNDLE="$PACKAGE_ROOT/DevScope.app"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
mkdir -p "$PACKAGE_ROOT"

DEVSCOPE_DIST_DIR="$PACKAGE_ROOT" \
DEVSCOPE_SIGN_IDENTITY="-" \
DEVSCOPE_ENTITLEMENTS="$ROOT_DIR/config/DevScopeDeveloperID.entitlements" \
DEVSCOPE_HARDENED_RUNTIME=1 \
DEVSCOPE_MARKETING_VERSION="$MARKETING_VERSION" \
"$ROOT_DIR/script/build_release_bundle.sh" >/dev/null

DEVSCOPE_REQUIRE_SANDBOX=0 \
DEVSCOPE_REQUIRE_APPLE_EVENTS=1 \
"$ROOT_DIR/script/validate_release_bundle.sh" "$APP_BUNDLE"

cat >"$PACKAGE_ROOT/UNNOTARIZED_COMMUNITY_PREVIEW.txt" <<NOTICE
UNNOTARIZED COMMUNITY PREVIEW

This DevScope build is ad-hoc signed and is not notarized by Apple. macOS
Gatekeeper may refuse to open it. Do not disable Gatekeeper or other macOS
security protections. If this preview is blocked, build DevScope from the public
source or wait for a Developer ID signed and notarized release.

Source: https://github.com/rsitech-ai/devscope
Commit: $SOURCE_COMMIT
Version: $MARKETING_VERSION ($PREVIEW_LABEL)
NOTICE

for exact_output in "$ZIP_PATH" "$CHECKSUM_PATH"; do
  if [[ -e "$exact_output" ]]; then
    unlink "$exact_output"
  fi
done

/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$PACKAGE_ROOT" "$ZIP_PATH"

ARCHIVE_ENTRIES="$(zipinfo -1 "$ZIP_PATH")"
if grep -Eq '(^|/)__MACOSX(/|$)|(^|/)\._' <<<"$ARCHIVE_ENTRIES"; then
  echo "error: preview archive contains AppleDouble metadata" >&2
  exit 1
fi
grep -Fq "$PACKAGE_NAME/DevScope.app/Contents/MacOS/DevScope" <<<"$ARCHIVE_ENTRIES" \
  || { echo "error: preview archive is missing DevScope.app" >&2; exit 1; }
grep -Fq "$PACKAGE_NAME/UNNOTARIZED_COMMUNITY_PREVIEW.txt" <<<"$ARCHIVE_ENTRIES" \
  || { echo "error: preview archive is missing its trust warning" >&2; exit 1; }

ARCHIVE_NAME="$(basename "$ZIP_PATH")"
ARCHIVE_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$ARCHIVE_NAME" >"$CHECKSUM_PATH"

printf 'Community preview archive: %s\n' "$ZIP_PATH" >&2
printf 'SHA-256 manifest: %s\n' "$CHECKSUM_PATH" >&2
printf '%s\n' "$ZIP_PATH"
