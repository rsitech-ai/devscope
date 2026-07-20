# Publication Gate Matrix

| Gate | Completion evidence | Authority |
|---|---|---|
| License and notices | Apache-2.0 text, NOTICE, third-party notices, checker pass | Repository maintainer |
| Community health | Contributing, conduct, support, governance, security, privacy, issue and PR templates | Repository maintainer |
| Source integrity | Strict tests and release build, clean diff, shell/plist checks | Engineering |
| Supply-chain disclosure | Dependency graph reviewed; actions pinned to full SHAs; manifest current | Engineering |
| Secret/privacy history | Fresh public history excludes legacy objects; exact-tree secret scan and source-archive inspection pass | Security/release reviewer |
| Repository settings | Visibility, branch protection, required reviews/checks, private vulnerability reporting, security features | Repository owner |
| Public source release | Exact reviewed commit tagged or published with accurate notes | Repository owner |
| Direct-download binary | Developer ID, hardened runtime, notarization, stapling, Gatekeeper, exact-bundle smoke | Apple/release owner |
| Community prerelease | Ad-hoc signature disclosed, trust warning embedded, checksum published, exact-bundle smoke | Release owner |
| Mac App Store binary | Explicit reduced product scope, provisioning, validation, upload, review | Product and Apple account owner |

No row implies completion of a later row. In particular, public source does not
make an ad-hoc signed preview production-ready, and a packaging smoke does not
prove App Store product viability.
