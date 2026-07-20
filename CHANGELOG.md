# Changelog

All notable changes to DevScope are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Recorded Rafal Sikora as copyright owner and RSI Tech as the public
  maintainer, with `rsitech.ai` and `info@rsitech.ai` as the project routes.
- Updated release evidence to distinguish the installed Developer ID identity
  from the still-missing notarization credentials and Keychain profile.

## [0.1.0-preview.1] - 2026-07-20

### Added

- Apache-2.0 licensing and an explicit open-source publication contract.
- Contribution, governance, security, privacy, support, and conduct policies.
- Deterministic public-source readiness validation.
- Installation, update, uninstall, troubleshooting, and maintainer release procedures.
- CI validation for both sandbox and full-access bundle policies.
- Fresh-history publication under the `rsitech-ai` GitHub organization.
- A reproducible checksummed community-preview packager with an embedded
  unnotarized-build warning.

### Fixed

- Recovery-cache payload limits now account for JSON escaping and reject oversized encoded metadata before writing, so every accepted save remains readable.
- Sensitive HTTP header redaction now removes complete Digest, AWS signature, proxy-authorization, and cookie values.
- Partial filesystem mutations now expose exact local recovery locations with Copy Path and Reveal in Finder actions.
- Table context-menu command copying now updates the same durable redacted recovery payload as the command bar.
- Development staging now re-signs the completed app bundle so Info.plist and resources are covered.
- Release app bundles now embed Apache-2.0 and third-party notice files.

### Added

- Native macOS running-activity inspection with process hierarchy and live resource metrics.
- Local process actions with explicit TERM, tree-termination, and force-kill boundaries.
- Automation inventory and management for supported local launchd, login-item, and cron sources.
- Optional on-device Foundation Models enrichment with deterministic scanner facts as authority.
- Local recovery for bounded copied-command and export data.
- Universal local and sandbox validation paths for Apple silicon and Intel slices.
