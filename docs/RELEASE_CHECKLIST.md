# DevScope Release Checklist

DevScope is a local process monitor and process-control utility. Treat release work as a security and distribution exercise, not only a build step.

## Required Before GitHub Release

- [ ] Run `swift test`.
- [ ] Run `swift build`.
- [ ] Run `swift build -c release`.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Run `./script/sandbox_smoke.sh`.
- [ ] Build and validate an ad-hoc full-access bundle with `config/DevScopeDeveloperID.entitlements`.
- [ ] Run a redacted full-history Gitleaks scan and inspect reachable historical images and author metadata.
- [ ] Smoke test live process refresh, search, category filters, sorting, Settings, Sponsor, graph display, copy/open-folder actions, and kill confirmation dialogs.
- [ ] Sign the app with a Developer ID Application certificate.
- [ ] Enable hardened runtime for outside-App-Store distribution.
- [ ] Notarize the signed app and staple the notarization ticket.
- [ ] For full-feature public distribution, run `./script/package_developer_id.sh` with Developer ID signing and notary credentials.
- [ ] Publish exact install, update, privacy, and uninstall instructions.
- [ ] Follow the exact sequence in `docs/RELEASING.md` and record the final commit and artifact digests outside that self-referential commit.

## Required Before Mac App Store Submission

- [x] Decide whether Mac App Store is compatible enough to test. DevScope now has a sandboxed package path, but process inspection and signaling must be manually verified under App Sandbox before upload.
- [x] Add App Sandbox entitlements.
- [x] Add packaged privacy manifest.
- [x] Add generated app icon to the release bundle.
- [x] Add release bundle validation script.
- [x] Add App Store package script.
- [x] Test sandbox-signed launch.
- [x] Compile and run the complete test inventory with the current release toolchain; preserve documented stable-toolchain compatibility.
- [x] Compare full-access and App-Sandbox behavior on macOS 27. Full access: 921 processes. Sandbox: 0 processes with explicit blocked state.
- [ ] Resolve App Sandbox scanner blocker. Current sandbox evidence: app launches but `/bin/ps` is blocked and the native `libproc` fallback returns no visible process records, so the app shows zero tracked processes.
- [ ] Create the App Store Connect app record for the final bundle identifier.
- [x] Install Mac App Store application and installer signing identities.
- [ ] Download or create a provisioning profile for the final bundle identifier.
- [ ] Build an App Store package with `./script/package_app_store.sh`.
- [ ] Verify which process-scanning and termination features still work in the sandboxed release app.
- [ ] If sandboxing breaks core functionality, ship via Developer ID/notarization instead of weakening user expectations in the App Store build.
- [ ] Provide App Review notes explaining process visibility, kill behavior, local-only data handling, and why requested permissions are needed.

## Privacy and Safety Copy

- DevScope scans local process metadata using system tools.
- DevScope does not require network access for process scanning.
- Apple naming, when available, runs through Apple platform APIs and falls back to deterministic local labels when unavailable or unsafe.
- Termination actions require explicit user interaction and use normal user-owned process signaling.

## Useful Release Commands

```bash
./script/sandbox_smoke.sh
./script/validate_release_bundle.sh dist/release/DevScope.app
security find-identity -p codesigning -v
```

```bash
DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
DEVSCOPE_NOTARY_KEYCHAIN_PROFILE="devscope-notary" \
./script/package_developer_id.sh
```

```bash
DEVSCOPE_BUNDLE_ID="com.s1korrrr.DevScope" \
DEVSCOPE_MARKETING_VERSION="0.1.0" \
DEVSCOPE_BUILD_VERSION="1" \
DEVSCOPE_APP_STORE_SIGN_IDENTITY="Apple Distribution: YOUR NAME (TEAMID)" \
DEVSCOPE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: YOUR NAME (TEAMID)" \
DEVSCOPE_PROVISIONING_PROFILE="/path/to/DevScope.provisionprofile" \
./script/package_app_store.sh
```
