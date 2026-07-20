# Contributing to DevScope

Thank you for helping improve DevScope. This project accepts focused bug fixes,
tests, documentation, accessibility improvements, and maintainable product work.
RSI Tech maintains the project; see <https://rsitech.ai> or contact
`info@rsitech.ai` for project matters that do not belong in a public issue.

## Development environment

- macOS 14 or newer
- A current stable Xcode toolchain with Swift 6 support
- Git and a POSIX-compatible shell

Clone the repository, then run:

```bash
./script/check_open_source_readiness.sh
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
./script/build_and_run.sh --verify
```

The application is a Swift package. `DevScopeCore` holds testable domain and
system logic, while the `DevScope` executable composes macOS services and SwiftUI.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the boundaries.

## Safety rules

- Never commit secrets, credentials, provisioning profiles, private keys, or unredacted user logs.
- Never test termination behavior against a user's real work. Use an isolated fixture process you created and can safely stop.
- Keep process facts deterministic. On-device model output may enrich presentation but must not control destructive actions.
- Preserve confirmation, authorization, and result-verification boundaries around process and automation mutations.
- Add a focused regression test for behavior changes and one realistic smoke check when system integration changes.
- Keep generated bundles, archives, derived data, and local release evidence out of Git.

## Pull requests

1. Open an issue first for large behavior or architecture changes.
2. Keep the change scoped and explain the user-facing outcome and risk.
3. Include tests and update public documentation when behavior or guarantees change.
4. Complete the pull-request checklist and wait for required checks and review.
5. Do not include unrelated formatting or generated-file churn.

By contributing, you agree that your contribution is licensed under the
project's [Apache License 2.0](LICENSE), consistent with section 5 of that license.

Security vulnerabilities must not be filed as public issues. Follow
[SECURITY.md](SECURITY.md).
