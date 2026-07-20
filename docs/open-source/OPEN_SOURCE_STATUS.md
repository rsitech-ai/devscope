# Open-Source Status

## Current verdict

The canonical public repository is
[rsitech-ai/devscope](https://github.com/rsitech-ai/devscope). It is published
from a clean source snapshot with fresh Git history. The legacy private
`s1korrrr/devscope` history is deliberately not transferred because it contains
deleted local audit images and author metadata that are irrelevant to the public
project.

Each public snapshot must pass the deterministic checker, strict tests, release
build, exact-tree secret scan, review, and clean source-archive inspection. The
fresh-history route resolves the legacy-history privacy blocker without a force
push or disclosure of the private objects.

## Distribution boundary

Source publication is independent of binary production distribution. A
downloadable community prerelease may be ad-hoc signed and unnotarized only when
its archive and release notes say so prominently. The production direct-download
route still requires a real Developer ID identity, hardened runtime validation,
Apple notarization, ticket stapling, Gatekeeper assessment, and an exact-artifact
smoke test.

The sandbox build validates packaging constraints but currently does not provide
the full process-inspection product and must not be marketed as feature-equivalent.

## Final local gates

Run from a clean publication candidate:

```bash
./script/check_open_source_readiness.sh
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
bash -n script/*.sh
plutil -lint Resources/PrivacyInfo.xcprivacy config/*.entitlements
```

Also run an exact-tree secret scan, inspect a `git archive` of the exact public
commit, and verify the fresh public history contains no legacy objects.

The current dependency declaration and source-package inventory are recorded in
`OPEN_SOURCE_MANIFEST.json` and `SBOM.spdx.json`. They must be regenerated when
an external package or redistributed component is added.
