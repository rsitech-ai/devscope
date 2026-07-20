# Architecture

DevScope is a native Swift package with two primary modules:

- `DevScopeCore` contains deterministic models, process and automation policy,
  scanners, correlation, presentation state, command boundaries, and storage
  abstractions. It is designed for focused unit and integration testing.
- `DevScope` is the macOS executable. It composes AppKit/SwiftUI views, system
  adapters, application lifecycle, notifications, local file access, and
  optional Foundation Models presentation enrichment.

## Data and action flow

1. System adapters gather bounded process and supported automation facts.
2. Core services normalize those facts into explicit snapshots and inventories.
3. Presentation policy filters and groups deterministic records for the UI.
4. Optional on-device model output may improve labels or notes but cannot replace
   source facts or authorize actions.
5. User actions pass through scope and capability policy, explicit confirmation
   where required, system execution, and post-action result verification.

## Trust boundaries

- Operating-system command output, file content, process identifiers, and model
  text are untrusted boundary inputs and must be parsed or validated.
- Destructive process and automation operations remain user initiated.
- The App Sandbox build is a compatibility-validation surface with restricted
  visibility; it is not equivalent to the full direct-download product.
- Local support data is bounded and remains on the Mac unless the user exports or
  shares it.

## Distribution

SwiftPM builds are development artifacts. A production direct-download archive
must be universal where claimed, signed with Developer ID, hardened, notarized,
stapled, validated, and smoke-tested from the exact distributed bundle. App Store
distribution is a separate product because sandbox constraints currently block
the full process-inspection promise.
