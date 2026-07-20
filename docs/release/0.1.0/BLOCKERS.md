# Release Blockers

## Source publication follow-ups

The canonical public source is published through a fresh-history
`rsitech-ai/devscope` snapshot. Legacy private objects, internal audits,
monetization work, and author metadata are not transferred.

1. **Repository protections — Maintained.** Public visibility, pull-request
   protection, required `Full-history Gitleaks scan`, `macOS arm64`, and `macOS x86_64` checks, private
   vulnerability reporting, secret scanning, push protection, and Dependabot
   security updates are enabled on `rsitech-ai/devscope`. Re-verify after any
   organization policy change.
2. **Public archive — Release owner.** Inspect the exact public commit archive and
   record the tag, source commit, checksum, and all limitations in release
   metadata.

## Production binary gates

1. **Distribution route — Product owner.** The full-feature product requires direct Developer ID distribution. A reduced sandbox/App Store edition would be a separate scoped product.
2. **Notarization — Apple account owner.** The installed `Developer ID Application: Rafal Sikora (2NY8A789TN)` identity is usable. Configure a notary Keychain profile backed by App Store Connect credentials, then produce a hardened, timestamped, notarized, stapled archive that passes Gatekeeper.
3. **Clean-machine runtime — QA/release owner.** Install and exercise the exact notarized archive on a clean supported Mac, including permission guidance, core inspection, safe fixture termination, automation read paths, update/uninstall behavior, and log review.
4. **Compatibility — QA.** Minimum macOS 14 runtime and physical Intel hardware runtime remain unexecuted. Universal build validation is not a substitute for hardware/runtime coverage.
5. **Performance/accessibility — QA.** Instruments/memgraph and the complete VoiceOver, keyboard, increased-contrast, and Reduce Motion matrices remain unverified.
6. **Public metadata — Product owner.** Public ownership, maintainer, website, and contact are approved. Final release notes and any hosted update mechanism still require exact-artifact review.

An ad-hoc signed community prerelease is permitted only when the archive and
release page prominently state that it is unnotarized and not a production
Developer ID distribution artifact.

Local source, test, runtime, and package checks cannot close owner credentials,
hosted CI, Apple notarization, clean-machine, or physical-hardware gates.
