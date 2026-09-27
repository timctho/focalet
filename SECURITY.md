# Security policy

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting](https://github.com/timctho/zommi/security/advisories/new).
Include the affected Zommi version and operating system, a minimal reproduction,
the expected security boundary, and the impact. Remove credentials, private
transcripts, personal screenshots and browser profile data from attachments.

Please use a public issue for ordinary bugs. Do not publish exploit details or
private user data in a public issue while a vulnerability is being investigated.
Maintainers will coordinate a fix and disclosure through the private report.

## Supported versions

Security fixes target the latest stable release. Update to the latest version
before checking whether an issue persists; older previews are not maintained
as separate security branches.

## Relevant boundaries

Zommi sends reviewed context to the agent selected by the user. Agent tools,
providers and enabled permissions determine what happens after submission.
Full access is enabled by default; users can disable it in App settings.
See the [privacy policy](docs/privacy.md), [runtime permissions](docs/install.md#2-choose-the-agent-you-already-have),
and [capture limitations](docs/browser-context.md).
