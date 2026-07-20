# Security Policy

## Supported versions

Security fixes target the latest code on `main` and the most recent published
release. Older or unofficial builds may not receive fixes.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability. Use the repository's
GitHub **Security** tab and choose **Report a vulnerability**:

<https://github.com/rsitech-ai/devscope/security/advisories/new>

Include the affected version or commit, macOS version, reproducible steps,
impact, and any suggested mitigation. Remove secrets, real process arguments,
private paths, and unrelated personal data. If private vulnerability reporting
is unavailable, open a minimal public issue asking the maintainer to establish a
private contact channel; do not disclose the vulnerability there. If GitHub's
private reporting flow is unavailable, email `info@rsitech.ai` with the subject
`DevScope security report`. Do not send secrets that are not required to
reproduce the issue.

RSI Tech will assess reports on a best-effort basis, coordinate a fix and
disclosure when appropriate, and credit reporters who want attribution. This is
not an emergency-response service and no response-time guarantee is offered.

## Security boundaries

- DevScope runs with the current macOS user's authority and does not provide privilege escalation.
- Process and automation actions are security-sensitive. Confirmation, scope, authorization, and post-action verification must remain explicit.
- Optional Foundation Models output is never trusted to authorize a destructive action.
- Local logs, exports, commands, and paths may contain sensitive information and must be redacted before sharing.
- A local ad-hoc build is not a production distribution artifact. Public binaries require Developer ID signing, hardened runtime, notarization, stapling, and Gatekeeper validation.
