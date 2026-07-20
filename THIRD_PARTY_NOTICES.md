# Third-Party Notices

The Swift package currently declares no external package dependencies.

DevScope uses Apple platform frameworks supplied by macOS and the Xcode SDK.
Those frameworks are not redistributed by this repository and remain subject to
Apple's applicable terms. The release process must regenerate this dependency
statement if an external dependency or redistributed third-party asset is added.

Repository automation uses GitHub's `actions/checkout` at a pinned revision and
downloads the Gitleaks CLI at an explicit version with its release SHA-256
checksum verified before execution. They are CI tooling and are not linked into
or redistributed with the DevScope application.
