# DevScope Mac App Store Readiness

DevScope now has a reproducible Mac App Store preparation path, but the current product scope is **not ready for Mac App Store submission** because App Sandbox blocks the core process scanner in local validation.

Local macOS 27 validation compared the full-access and sandbox policies. The
full-access candidate populated process and automation inventory, while the
sandbox candidate showed no running processes and an explicit blocked state.
This confirms the distribution conflict on the target OS and SDK rather than
resolving it.

Current evidence:

- The sandbox-signed release bundle builds, signs, validates, and launches.
- The first sandboxed scanner path using `/bin/ps` is blocked with an operation-not-permitted error.
- A native `libproc` fallback was added and validated by unit tests outside the sandbox.
- Inside the sandboxed `.app`, the native fallback still returns no visible process records.
- The sandboxed app therefore reports `0 tracked processes`.

The final upload also depends on Apple account assets that must exist on the release Mac:

- a Mac App Store application signing identity (installed on the audited Mac)
- a Mac App Store installer signing identity (installed on the audited Mac)
- a provisioning profile for the final bundle identifier
- an App Store Connect app record using the same bundle identifier

The audited Mac has no provisioning profile matching `com.s1korrrr.DevScope`; the App Store Connect record has not been verified.

The current recommended bundle identifier is:

```bash
com.s1korrrr.DevScope
```

## What Is Prepared

- App Sandbox entitlement: `config/DevScope.entitlements`
- Privacy manifest: `Resources/PrivacyInfo.xcprivacy`
- App icon generation: `script/generate_app_icon.swift`
- Release bundle builder: `script/build_release_bundle.sh`
- Release validator: `script/validate_release_bundle.sh`
- Sandboxed local launch smoke: `script/sandbox_smoke.sh`
- Mac App Store package builder: `script/package_app_store.sh`

The release bundle contains:

- `Contents/Info.plist`
- `Contents/MacOS/DevScope`
- `Contents/Resources/AppIcon.icns`
- `Contents/Resources/PrivacyInfo.xcprivacy`
- App Sandbox entitlements in the code signature

## Local Sandbox Validation

Run this before attempting App Store signing:

```bash
./script/sandbox_smoke.sh
```

Expected result:

```text
Validated .../dist/release/DevScope.app
Sandbox: enabled
Sandbox smoke passed: .../dist/release/DevScope.app
```

This proves the app can be built, signed with sandbox entitlements, validated, and launched locally. It does **not** prove App Store readiness. The current sandbox smoke shows that both shell-based process scanning and native fallback process scanning are blocked or empty, which is a release blocker for the full DevScope feature set.

## App Store Package Build

After creating/downloading the App Store signing assets, this command builds the package. Do not upload it until the sandbox compatibility blocker is resolved.

```bash
DEVSCOPE_BUNDLE_ID="com.s1korrrr.DevScope" \
DEVSCOPE_MARKETING_VERSION="0.1.0" \
DEVSCOPE_BUILD_VERSION="1" \
DEVSCOPE_APP_STORE_SIGN_IDENTITY="Apple Distribution: YOUR NAME (TEAMID)" \
DEVSCOPE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: YOUR NAME (TEAMID)" \
DEVSCOPE_PROVISIONING_PROFILE="/path/to/DevScope.provisionprofile" \
./script/package_app_store.sh
```

If your Apple account uses a differently named modern signing identity, pass that exact identity string. You can inspect installed signing identities with:

```bash
security find-identity -p codesigning -v
```

The package script creates:

```text
dist/app-store/DevScope.pkg
```

Upload the package with Apple Transporter or App Store Connect tooling, then complete App Review metadata.

## App Review Notes

Use plain language in App Review notes:

- DevScope is a local developer utility for inspecting user-owned development processes.
- It scans local process metadata with system tools and does not require a server.
- It shows CPU, memory, elapsed runtime, command context, process tree context, and local workflow grouping.
- Termination actions require explicit user interaction and use normal user-owned process signaling.
- The app does not collect analytics, does not track users, and does not upload process data.
- Apple naming support is optional and deterministic scanner facts remain authoritative.

## Required Manual Smoke Before Upload

Run these against the sandbox-signed `dist/release/DevScope.app`:

- Live process table populates within a few seconds.
- Search filters process names, commands, PIDs, folders, and runtimes.
- Runtime Tree shows only detected runtime groups.
- Focus groups AI/ML, training, workspace, web, and local project groups correctly.
- CPU, memory, Apple GPU, and machine load graph update smoothly.
- Copy/export/folder actions work.
- `TERM` works against a disposable test process owned by the current user.
- `TERM Tree` works against a disposable parent/child process tree.
- Force kill remains behind the destructive menu.
- Settings and Support open correctly.

## If Sandbox Blocks Core Features

The current sandbox build blocks process scanning, even with the native fallback, so there are three honest release shapes:

1. Ship the full DevScope product outside the Mac App Store using Developer ID signing and notarization.
2. Build a reduced Mac App Store variant that does not promise process inspection/termination, or obtain an Apple-approved entitlement/path that restores the core behavior.
3. Ship both editions with distinct capability copy and separate runtime validation.

Do not submit a degraded build that misrepresents DevScope's process-control feature set.

## Full-Feature Public Release Fallback

For the full DevScope feature set, use Developer ID distribution until the App Store sandbox issue is resolved:

```bash
DEVSCOPE_DEVELOPER_ID_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
DEVSCOPE_NOTARY_KEYCHAIN_PROFILE="devscope-notary" \
./script/package_developer_id.sh
```

The Developer ID path signs with hardened runtime, uses non-sandboxed entitlements, creates a zip, submits it to Apple's notary service when a notary keychain profile is configured, staples the ticket, and verifies Gatekeeper acceptance.
