# Security Status

The standard repository scan targeted immutable revision `bedc3ac5a04e974ef2a3336e40866a88453bb1ff`. Thirty ranked high-priority files received full-file receipts. Four reportable medium/low candidates were reproduced and fixed in the release worktree:

1. Critical service protection no longer depends on presentation classification.
2. Redacted commands now cover common `redis-cli -a`, `mysql -p`, and `curl -u` credential forms.
3. TSV exports flatten row/cell separators and neutralize spreadsheet formula prefixes.
4. App Store packaging pins sandbox entitlements and sandbox-required validation; entitlement validation parses the exact plist value.

One low least-privilege candidate remains deferred: non-TCC `lsof` failures and genuine permission denial currently collapse to the same “zero CWDs” signal, which can lead to Full Disk Access guidance. It requires provenance-aware scanner changes and targeted failure injection. One adjacency-based entitlement validator candidate was suppressed by an actual signed-bundle counterexample, though the parser was hardened anyway.

No critical/high findings, remote attack surface, third-party dependency, committed credential, network listener, privileged helper, updater, WebView, or binary framework was found in that dated scan. Its readable report was stored outside the repository and is not a reproducible artifact of the current checkout; `RELEASE_MANIFEST.json` therefore does not claim or link current-snapshot scan proof.

That dated main-to-working-tree security diff scan covered all 22 source-like files changed in its `bedc3ac5a04e974ef2a3336e40866a88453bb1ff` scope, including the release workflow. It validated and fixed a `curl --user` / `--proxy-user` bulk-redaction gap and pinned `actions/checkout` to the then-reviewed immutable commit `34e114876b0b11c390a56381ad16ebd13914f8d5`. Both candidates were revalidated within that dated snapshot, whose sealed report recorded zero surviving reportable findings.

Residual risk: the earlier standard scan's lower-ranked baseline files remain outside that scan's full-file review, and the deferred `lsof` failure-provenance hardening remains open. That dated diff scan did not cover the current continuation.

## 2026-07-20 release continuation

The owner explicitly waived a fresh Codex Security app scan for this continuation.
Local regression work fixed complete-value redaction for Digest, AWS Signature,
proxy authorization, and cookie headers, and added exact recovery-path handling.
This is focused local evidence, not exhaustive current-snapshot scan coverage.

Four deleted screenshots in the legacy private history were visually confirmed
to expose local identity, workstation-path, process, and workspace information.
The canonical public repository therefore uses a fresh source snapshot and does
not transfer legacy commits, deleted objects, or private author metadata.

## 2026-07-14 automation-engine addendum

The layered automation engine adds a higher-risk local management surface and was reviewed against explicit ownership, canonical-path, stale-generation, content-validation, backup, postcondition, rollback, and process-birth gates. Runtime audit fixes closed independent source hangs, cancellation-ignoring source deadlines, ambiguous LaunchAgent runtime errors, stale Start Now verification, incoherent running projection, implicitly enabled duplicates, and command descendants that retained output pipes past leader exit. Commit `310f54c` then closed the final review findings with a shared typed `launchctl print` absence classifier, fail-closed identical-definition provenance, per-source quarantine for cancellation-ignoring refreshes, and four-worker deduplicated runtime discovery. Ordinary, AddressSanitizer, and ThreadSanitizer suites each passed 547/547; the focused controller rerun passed 105/105; the warnings-as-errors Release build and diff check passed.

The completed independent immutable whole-branch re-review found no Critical, Important, or Minor issue after those fixes. The changed slice has no surviving correctness or security finding. Product commands use fixed absolute executables plus argument arrays, recovery artifacts are 0700/0600 and content-authenticated, unknown launchd state is inspection-only, cross-app modern services remain read-only, imports reject symlinks/non-regular/oversized data, and unredacted export is owner-only. No shell interpolation, network transmission, new dependency, updater, privileged helper, credential, or public listener was introduced.

Residual automation risk is reported fail-closed: `/usr/bin/crontab <file>`
blocks in the current macOS 27 process context, and modern Login Items/Background
Items enumeration times out. The 30-second command deadline terminates and reaps
the complete child group; the independent 10-second source deadline preserves
healthy inventory. These integrations must not be described as fully operational
on this host until a permission/toolchain change enables verified write/readback
or enumeration.
