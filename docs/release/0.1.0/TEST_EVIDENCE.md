# DevScope 0.1.0 Test Evidence

- Evidence date: 2026-07-20
- Canonical publication target: `rsitech-ai/devscope` `main`
- Audited product baseline: `e8f3f973dcb94f83c89ba73bbde600bc7c920e1e`
- Candidate delta: credential redaction, exact recovery-path presentation, durable command-copy recovery, coherent development-bundle signing, embedded release license notices, dual-policy CI, and public release documentation
- Host: macOS 27.0 (beta host)
- Toolchain: Xcode 26.6, Swift 6.3.3

## Source verification

- `./script/check_open_source_readiness.sh`: passed.
- `swift test -Xswiftc -warnings-as-errors`: 669 tests, 0 failures.
- `swift build -c release -Xswiftc -warnings-as-errors`: passed.
- `bash -n script/*.sh`: passed.
- `plutil -lint Resources/PrivacyInfo.xcprivacy config/*.entitlements`: passed.
- GitHub YAML parsed with Ruby Psych: all workflow, issue-form, funding, and Dependabot files passed.
- `gitleaks dir --redact --no-banner --no-color .`: approximately 81.15 MB, no pattern findings.
- Public snapshot `gitleaks dir --redact --no-banner --no-color .`: required at the exact organization PR commit.
- Clean `git archive` verification: readiness, all 669 strict tests, the warnings-as-errors release build, and exact-tree Gitleaks must pass from the exact public commit extraction.
- Public history inspection: the organization repository is seeded from a fresh source snapshot and must contain no legacy private commits or deleted objects.
- Hosted Secret Scan and Release Gates results must be recorded from the exact organization PR rather than inherited from the legacy personal repository.
- Official Apache-2.0 text comparison: byte-for-byte match.

The Gitleaks policy contains narrowly scoped rule, path, and line-pattern
exceptions for synthetic credential-redaction tests and published artifact
SHA-256 digests. It does not exclude an entire test or documentation tree.

## Runtime and package verification

- `script/build_and_run.sh --verify`: exact staged development binary launched and matched its executable; the completed bundle passed strict signature verification.
- Real UI smoke: Automations loaded with explicit diagnostics; Processes loaded live inventory; exact-PID search, process detail, self-protection, and durable command copy were exercised.
- Full-access local package: version 0.1.0 (1), `x86_64 arm64`, App Sandbox absent, Apple Events entitlement present, strict signature and policy validation passed, with license notices embedded.
- Sandbox package: version 0.1.0 (1), `x86_64 arm64`, required sandbox and user-selected read-write entitlements present, strict signature and policy validation passed, with license notices embedded.

Artifact SHA-256 digests must be recorded from the exact merged/final artifact
in GitHub release metadata or another immutable exact-build record; none is
claimed by this candidate document.

The reviewed recovery-cache repair modifies application source. Fresh artifact
hashes must therefore be recorded from the exact merged release build rather
than inherited from the earlier audited baseline.

## Distribution boundary

This is verified source and local runtime/package evidence. It is not Developer
ID signing, notarization, Gatekeeper approval, App Store validation, TestFlight
upload, clean-machine installation proof, or App Review approval.
