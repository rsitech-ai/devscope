# Installation and Maintenance

DevScope ships as source and as an optional community prerelease. The community
archive is ad-hoc signed and not notarized by Apple. There is no notarized public
binary and no in-app updater yet.

## Requirements

- macOS 14 or newer
- A current stable Xcode toolchain with Swift 6 support
- Git and a POSIX-compatible shell

## Run from source

From the repository root:

```bash
./script/build_and_run.sh --verify
```

This builds and launches `dist/DevScope.app` as a local development artifact.

## Download the community prerelease

Download both the macOS universal zip and its `.sha256` file from
[GitHub Releases](https://github.com/rsitech-ai/devscope/releases), keep them in
the same directory, and verify the archive:

```bash
shasum -a 256 -c DevScope-*.zip.sha256
```

The archive contains `DevScope.app` and
`UNNOTARIZED_COMMUNITY_PREVIEW.txt`. Read that warning before opening the app.
The preview is ad-hoc signed and not notarized, so Gatekeeper may reject it. Do
not disable Gatekeeper or other macOS security protections. Build from source if
the preview is blocked, or wait for a Developer ID signed and notarized release.

## Install the full local app

```bash
./script/install_local_full_build.sh
```

The installer builds the non-sandbox process-control variant, validates its
bundle policy, places it at `/Applications/DevScope.app`, and launches it. This
is a local build, not Developer ID/notarization proof.

## Update

DevScope has no automatic updater. Review and fetch the desired source revision,
rerun the readiness/tests appropriate to that revision, then rerun:

```bash
./script/install_local_full_build.sh
```

A future signed release must publish its own exact update and checksum guidance.

## Uninstall

Quit DevScope and move `/Applications/DevScope.app` to Trash in Finder. The app
does not install a privileged helper or background updater.

DevScope keeps preferences and bounded recovery data under the current user's
Library, including `~/Library/Application Support/DevScope`. Remove that folder
only if you also want to delete local recovery/backups; inspect it first because
that cleanup is permanent once Trash is emptied.

## Troubleshooting

### No processes or working directories appear

Do not use `script/sandbox_smoke.sh` as the daily install. App Sandbox blocks the
full machine-wide scanner. Install the full local build, then open **Settings >
Access** for DevScope's exact Ready, Needed, or Blocked explanation. DevScope
cannot grant itself Full Disk Access or bypass App Sandbox.

### The app does not launch from a source build

Confirm `xcodebuild -version` and `swift --version` satisfy the requirements,
then run `./script/build_and_run.sh --verify` and use its first build or bundle
validation error. Do not bypass Gatekeeper for an untrusted downloaded binary.

### Restore last copy is unavailable

Copy a process command or visible-row export from DevScope first. Recovery stores
a bounded redacted payload; it deliberately does not preserve unredacted secrets.

### Repositories are grouped under an owner-folder name

For layouts such as `~/dev/acme-labs/project`, launch DevScope with
`DEVSCOPE_WORKSPACE_OWNER_COMPONENTS=acme-labs` (comma-separate multiple names).
DevScope will then select the repository below that configured owner folder.
Without explicit structure, it conservatively treats the first component after
the development root as the project so nested working directories remain stable.

For bugs, support, privacy, and security-reporting routes, see
[SUPPORT.md](../SUPPORT.md), [PRIVACY.md](../PRIVACY.md), and
[SECURITY.md](../SECURITY.md).
