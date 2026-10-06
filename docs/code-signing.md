# Code signing policy

## Current status

The v0.3.0 Windows applications and installers for Capture and Desktop are
unsigned. No SignPath certificate has been approved or connected to the release
workflow. A checksum verifies that
a download matches a published file; it does not establish publisher identity.
Consult each release's signing metadata for that release's actual status.

Focalet is evaluating the [SignPath Foundation program](https://signpath.org/).
Acceptance is subject to its review. If approved, its certificate would identify
**SignPath Foundation** as the publisher. We will update this page and release
notes when signed distribution is available.

## Responsibilities and approval

- Authors and reviewers: repository maintainers, currently [Tim Ho (@timctho)](https://github.com/timctho).
- Release and signing approver: [@timctho](https://github.com/timctho).

Maintainers participating in signing must use MFA for GitHub and the signing
service. A maintainer must review and explicitly approve each signing request;
automatic publication cannot bypass a signing provider's approval requirement.

## What will be signed

Sign only Focalet's own binaries built from the public repository and the final
Windows installer. Preserve upstream signatures and notices; do not sign
third-party libraries as if they were maintained by Focalet. Use timestamped
Authenticode signatures and verify them before publishing.

The release pipeline must bind the source revision, successful CI checks,
artifacts and signing request together. Recompute checksums after signing.
Published tags and release assets are immutable: publish a new version when
introducing signed builds. Signing establishes publisher identity but does not
guarantee immediate SmartScreen reputation.

See [release preparation](public-releases.md), [privacy](privacy.md), and
[security reporting](../SECURITY.md).
