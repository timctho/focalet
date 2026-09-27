# Privacy policy

Zommi connects desktop context to an agent you choose. This page describes the
desktop application's data handling; your selected agent, model provider and
connected services have their own policies.

## What capture includes

Capture starts when you invoke a selection. An attachment can contain selected
pixels, your annotations, text, links, element structure, coordinates, window
titles, application and process identity, and the capture host name. Context
from an intersecting element can extend beyond the selected pixels. Reliable
alignment is not always available; Zommi explains image-only fallbacks.

Review an attachment and its Details before submitting. Remove it from the draft
if it contains information you do not want to share. Attaching a selection does
not itself submit the message. [Capture controls and limitations](browser-context.md)
describe the fields and capture budgets.

## Where information goes

When you send a message, Zommi hands the message and attachments to the selected
agent runtime. Depending on that runtime's configuration, it may send them to a
cloud model provider, a configured gateway, or other services through agent tools.
Zommi does not operate a hosted service for collecting your conversations and
does not include application analytics or advertising telemetry.

The runtime owns sign-in and canonical conversation history. Authentication,
retention, training use and deletion at a provider are governed by that provider's
settings and terms. Consult the privacy documentation for the actual provider
you configure; an agent can support more than one provider.

## Local information

Zommi stores preferences, runtime connection metadata and a session metadata cache
on your machine. The cache contains items such as session IDs, titles, workspaces
and activity timestamps. Inactive cached metadata expires after seven days;
current and running chats are retained. Capture helpers can use local temporary
files to deliver attachments. Agent runtimes may retain their own copies.

See [local state and recovery](desktop-reference.md#local-state-and-recovery)
for platform locations. Clearing Zommi's cache does not delete agent or provider
history. Follow the [uninstall guide](install.md#update-uninstall-and-verify) to
remove the app and its optional local state.

## Browser connections and permissions

Optional browser context uses a browser debugging connection you authorize.
Edge and Chrome have separate connection controls. Disconnecting a browser or
disabling browser context stops Zommi's browser context access; agent-owned
browser tools have separate connections and permissions.

Full access (YOLO) is on by default and allows agent actions without individual
approval prompts. Disable it in App settings to follow each runtime's permission
policy. Operating-system screen recording and accessibility permissions are
managed separately. [Installation and permissions](install.md) explains both.

## Downloads, documentation and reports

GitHub hosts this repository, downloads and documentation. GitHub's
[privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
applies when you use those services. The documentation site adds no analytics
service; its search index is downloaded and searched in your browser.
Public GitHub issues are visible to everyone. Share only sanitized diagnostics.
For privacy or security vulnerabilities, use the [private reporting process](../SECURITY.md).
