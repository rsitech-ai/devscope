# DevScope 0.1.0 Community Preview Release Notes

Initial release candidate hardening includes:

- Universal Apple silicon and Intel Release bundles.
- Clear sandbox-versus-full-build access diagnostics.
- Single-window process scanner ownership.
- Scrollable settings, reduced-motion support, accessibility announcements, and accessible graph summaries.
- Truthful folder/recovery feedback.
- Hashed favorite/watch identity persistence with one-time legacy-key migration.
- Stronger credential redaction and safe spreadsheet export.
- Actionable file-mutation recovery locations with Finder and copy-path actions.
- Durable copy recovery shared by command-bar and table context-menu actions.
- Classification-independent protected-process enforcement.
- Fail-closed App Store sandbox packaging and exact entitlement validation.
- Configured macOS 26 CI gates for Apple silicon and Intel runners, covering both sandbox and full-access bundle policies.

The downloadable community preview is ad-hoc signed and not notarized by Apple.
It is not a production Developer ID or approved App Store build. The canonical
public source uses fresh Git history under `rsitech-ai/devscope`; legacy private
audit objects and author metadata are not included. Developer ID signing,
notarization, stapling, Gatekeeper approval, clean-machine proof, and App Store
submission remain open.
