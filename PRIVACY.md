# Privacy

DevScope is a local-first macOS process and automation inspection tool. It does
not require an account, operate a project backend, include advertising or
analytics SDKs, or intentionally send process data to the project maintainer.

## Data processed on the Mac

Depending on enabled features and macOS permissions, DevScope may read:

- running-process identifiers, names, commands, executable paths, parent/child relationships, resource usage, and working-directory hints;
- supported local automation metadata, such as launchd definitions, login items, and user cron entries;
- user preferences and bounded local history needed for graphs, favorites, watch state, and workflow presentation;
- the last command or export copied through DevScope, stored in a bounded recovery file in Application Support so it can be restored after relaunch.

Process commands and paths can contain sensitive project names, arguments, or
local usernames. Review exports and screenshots before sharing them.

## Optional on-device intelligence

When Apple Foundation Models are available and the feature is enabled, DevScope
may use the operating system's on-device model APIs to improve process names or
workflow notes. Model output is presentation-only; deterministic scanner facts
remain authoritative and model output does not authorize destructive actions.

## Storage and deletion

DevScope stores preferences and bounded support data in the current user's macOS
Library containers/Application Support locations. Preferences can be reset in
the app where offered. Removing DevScope's related Application Support and
preferences data deletes local app state; uninstalling the app alone may leave
those standard macOS support files in place.

## Network behavior

Core scanning and automation features do not require a project-operated network
service. User-invoked support actions can open the documented Buy Me a Coffee
website in the default browser. macOS or Apple frameworks may have their own
system behavior and policies.

## Permissions and control

DevScope does not use privileged APIs. macOS controls which processes and files
the current user may inspect or change. Full Disk Access may improve visibility
for protected metadata, but it does not bypass normal process ownership or
authorization rules. App Sandbox builds have a substantially reduced feature set.

For a security issue, follow [SECURITY.md](SECURITY.md). For other privacy
questions, open a repository issue without attaching sensitive process data.
