# DevScope 0.1.0 Release Status

## Current verdict

**SOURCE PUBLICATION APPROVED / COMMUNITY PRERELEASE ROUTE READY / PRODUCTION BINARY BLOCKED — 2026-07-20.**

The repository contains an Apache-2.0 license, public contribution and security
policies, privacy and architecture disclosures, pinned CI automation, a source
manifest and SPDX SBOM, and a deterministic publication checker. The canonical
public repository is `rsitech-ai/devscope`, seeded from a clean source snapshot
with fresh Git history. The legacy personal repository and its deleted audit
objects are not transferred.

The full-feature local bundle is universal (`x86_64 arm64`), ad-hoc signed,
structurally validated, and runtime proven. A checksummed community prerelease
may be published only with an embedded unnotarized warning. Production binary
distribution remains **BLOCKED:EXTERNAL** because the installed Developer ID
identity has no configured notary Keychain profile, so no notarized, stapled,
and Gatekeeper-approved artifact was produced. Sandbox
packaging passes, but the sandbox product is not feature-equivalent.

## Verified gates

| Gate | Status | Evidence |
|---|---|---|
| Public-source contract | PASS | Apache-2.0, NOTICE, community/security/privacy/governance files, architecture, manifest, SPDX SBOM |
| Deterministic source gate | PASS | `script/check_open_source_readiness.sh` |
| Public history and tree | PASS BY CONSTRUCTION | Canonical publication uses fresh history from the exact sanitized source archive; legacy private objects and author metadata are not transferred; exact-tree Gitleaks remains required |
| Dependency declaration | PASS | Swift package dependency graph is empty; third-party notices and SBOM agree |
| Strict test suite | PASS | 671 tests, 0 failures, warnings treated as errors |
| Strict release build | PASS | Production build completed with warnings treated as errors |
| Exact development runtime | PASS | Exact staged bundle launched, matched to its running executable, and passed strict bundle-signature verification; Processes and Automations received a real UI smoke |
| Universal full-access package | PASS (local) | `x86_64 arm64`, Apple Events entitlement, App Sandbox absent, signature/policy validation passed, license notices embedded |
| Universal sandbox package | PASS (constrained) | `x86_64 arm64`, sandbox and user-selected read-write entitlements, signature/policy validation passed, license notices embedded |
| Community prerelease | READY (unnotarized) | Explicit acknowledgement, ad-hoc signature disclosure, embedded trust warning, clean universal zip, and published SHA-256 required |
| Developer ID identity | PASS (installed) | `Developer ID Application: Rafal Sikora (2NY8A789TN)` is available with its private key |
| Notarization | BLOCKED:EXTERNAL | No `devscope-notary` Keychain profile or equivalent App Store Connect credentials are configured |
| Repository publication settings | PASS | Public `rsitech-ai/devscope`; branch protection with required PR, conversation resolution, and admin enforcement; private vulnerability reporting enabled; secret scanning, push protection, and Dependabot security updates enabled |
| Remote required checks | PASS | `Secret Scan` and `Release Gates` are required status checks on `main`; organization PR and main-branch workflow runs recorded green |
| Exact hardened-source archive | PASS (local) | The source tree passed readiness, 671 strict tests, warnings-as-errors release build, and exact-tree Gitleaks from a clean `git archive`; repeat from the exact public commit |

## Log boundary

The exact development bundle produced no DevScope-owned error or fault during
the fresh scan interval. The macOS 27 beta host emitted framework-owned App
Intents/CoreSpotlight connection and donation errors because Apple host services
were unavailable. These are documented platform diagnostics, not a claim that
the complete unified system log is silent.

## Release policy

- Record the exact source commit in the release tag or GitHub release; do not hardcode a self-referential commit in tracked evidence.
- Do not publish an ad-hoc signed local bundle as a production download.
- Publish an ad-hoc signed archive only as an explicitly unnotarized community prerelease with its checksum and trust warning.
- Do not market the sandbox build as the full-feature product.
- Treat source publication, Developer ID distribution, and Mac App Store distribution as independent gates.
