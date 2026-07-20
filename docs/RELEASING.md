# Maintainer Releasing

This procedure prepares one exact DevScope source commit and its macOS artifacts.
Repository publication and release creation require explicit owner authority.
Developer ID use, notarization, and App Store submission remain separate
credentialed actions.

## 1. Establish the candidate

Start from the intended `main`, confirm the working tree is clean, and record the
exact commit, toolchain, supported platform claims, and unresolved owner gates.
Do not tag while `docs/release/0.1.0/BLOCKERS.md` contains an unaccepted
publication blocker.

## 2. Validate source and policy

```bash
./script/check_open_source_readiness.sh
swift package show-dependencies --format json
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash -n script/*.sh
plutil -lint Resources/PrivacyInfo.xcprivacy config/*.entitlements
git diff --check
```

Run the checksum-pinned Gitleaks workflow or an equivalent local Gitleaks 8.30.1
full-history scan with redacted output. Separately inspect reachable deleted
images and Git author metadata; a secret scanner does not close visual privacy or
identity disclosure.

## 3. Rehearse both product policies

Build the sandbox compatibility bundle:

```bash
DEVSCOPE_DIST_DIR="$(mktemp -d)/sandbox" \
  ./script/build_release_bundle.sh
```

Validate its App Sandbox and user-selected-file entitlements with
`DEVSCOPE_REQUIRE_SANDBOX=1 ./script/validate_release_bundle.sh <app-path>`.

Build the full-access local candidate with
`config/DevScopeDeveloperID.entitlements`, then validate with
`DEVSCOPE_REQUIRE_SANDBOX=0` and `DEVSCOPE_REQUIRE_APPLE_EVENTS=1`. An ad-hoc
signature proves bundle policy only; it is not a distributable production
signature. Confirm each candidate contains `LICENSE`, `NOTICE`, and
`THIRD_PARTY_NOTICES.md` under `Contents/Resources`.

Run `./script/build_and_run.sh --verify`, exercise the README quickstart and the
primary Processes/Automations paths, and review DevScope-owned logs.

## 4. Rehearse the exact source archive

Create a `git archive` from the exact candidate commit in a temporary directory.
Inspect its file list, build and test from the extracted archive, rerun the
quickstart where practical, and confirm no ignored local files are required.
Record archive and artifact SHA-256 digests in the GitHub release or another
immutable release record; do not hardcode a self-referential final commit digest
inside that same commit.

## 5. Production distribution

Only after the owner supplies and authorizes the signing/notary inputs, run:

```bash
DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
DEVSCOPE_NOTARY_KEYCHAIN_PROFILE="devscope-notary" \
./script/package_developer_id.sh
```

Require hardened runtime, timestamped signing, notarization acceptance, stapling,
Gatekeeper approval, checksum publication, and a clean-machine install/runtime
smoke of the exact archive. Keep the reduced sandbox/App Store route separate.

### Community prerelease fallback

When no Developer ID identity or notary profile is available, maintainers may
produce a clearly labeled ad-hoc signed prerelease:

```bash
DEVSCOPE_SOURCE_COMMIT="$(git rev-parse HEAD)" \
DEVSCOPE_ACKNOWLEDGE_UNNOTARIZED_PREVIEW=1 \
  ./script/package_community_preview.sh
```

The script validates the universal full-access bundle, packages an explicit
`UNNOTARIZED_COMMUNITY_PREVIEW.txt`, rejects AppleDouble metadata, and writes a
SHA-256 manifest. Publish it only as a GitHub **prerelease** whose title and first
paragraph say that it is ad-hoc signed and not notarized. Never describe this
fallback as a production, Developer ID, Gatekeeper-approved, or notarized build.

## 6. Publish and verify

After explicit external-action approval, push the exact candidate, require green
hosted checks, protect the default branch and release tags, publish the tag and
release, and inspect the repository signed out. Recheck security settings and
protections after any visibility change. Follow
[Installation and maintenance](INSTALLATION.md) for user-facing lifecycle copy.
