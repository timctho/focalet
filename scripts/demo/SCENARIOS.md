# Three demos: point once, skip the explanation

Use Amazon shopping, latency investigation and interactive Sheets editing, in
that order. The difficult part is identifying the exact objects or context the
user means. Target roughly 25–40 seconds per edited clip, with quick gestures,
short prompts and readable results. The [gallery](../../docs/demos/README.md)
contains the reviewed recordings; this brief alone is not acceptance evidence.

| Case | Context that is expensive to describe | User action | Payoff |
| --- | --- | --- | --- |
| Amazon | Five similar products, exact variants, and misleading dual-monitor labels | One loose rectangle around a row of real listing cards | Agent checks every exact listing against an M1 Air's display limit |
| Dashboard | Which latency spike, time buckets, metric definition and query | Select only the spike interval | Agent receives the full executed query and selected points, then investigates the database |
| Sheets | Which region each different layout instruction refers to | Loosely frame both blocks, then ask once | A becomes compact and navy; B becomes spacious and orange |

## 1. Amazon: one grid, all candidates

Use the real, signed-out Amazon listing grid. Frame the entire candidate row
once. Do not switch to individual detail pages to attach each product. The
[recorded sources](amazon/README.md) identify the five candidates in this take.

Ask: **“Which of these would let my M1 MacBook Air run two independent monitors?
Check the exact listings. Keep the comparison short and link the sources.”**

The laptop model belongs in the question; candidate URLs and specifications must
arrive through the native capture. Let the actual agent follow every selected
product link, read additional compatibility details and provide a sourced
comparison. Do not predeclare a winner: this take finds that none of the five
meets the independent-display requirement.

`amazon_proof.py` requires one aligned image, at least three distinct native DOM
product links, a completed agent investigation of every candidate and a final
comparison linking each one. The capture may be truncated; full-page product
details are obtained using the agent's browser tools. Record availability and
prices as observations from that take. Keep account information, delivery
addresses, personal recommendations and checkout out of the published crop.

## 2. Dashboard: only the latency spike

Use [latency/](latency/README.md) and the [storyboard](DASHBOARD-STORYBOARD.md).
Draw one rectangle over the 14:30–14:40 spike. Leave the rest of the chart and
Query Inspector outside the rectangle.

Ask: **“Why did latency spike here? Check the underlying query and source data.
Give me the cause and strongest evidence in 3 short bullets.”**

The chart exposes its actual executed SQL as a standard accessibility
description. Each point exposes its timestamp, value and bucket size. Verify
that the native region captures the complete SQL and only the three selected
points. The agent already has authorized access to the synthetic workspace; it
must run the query and compare the database records and deployments itself.

`latency_proof.py` rejects missing query metadata, a selected SQL editor, points
outside the spike, unfinished analysis and modified source data. This fixture
explicitly exposes its query; the demo does not establish hidden-query discovery
for arbitrary dashboard applications.

## 3. Sheets: A and B get different layouts

Use the private synthetic [Event layout fixture](sheets/README.md). Capture
both blocks in one native selection: hold Ctrl for the first rectangle, draw
the second, then attach both. Leave extra space and cross cell borders
naturally. The outlines should feel casual.

Ask: **“Make A compact with navy headers. Make B spacious with orange headers,
taller rows and larger text. Keep values and formulas.”**

The prompt supplies no URL or cell addresses. The real agent must use the
captured source identity and images to distinguish A from B, inspect the actual
cells, and apply each instruction to its own area through its browser tools.

Keep a clear shot of the cramped, unstyled original, both quick selections,
the single request, and a large view of the completed layout. Verify both
blocks' styles against ordered authenticated workbook exports: the upper
reference must have navy headers; the lower must have orange headers, taller
rows and larger text. A color-only difference or swapped styles is insufficient.
Preserve all values and formulas,
including the unrelated original tab. `sheets_layout_proof.py` gates this
`contrasting-layouts` scenario, including the captured reference order and
explicit references in the request. Older verifiers remain for historical takes.

## Editing and review

Keep the successful selection, attachment, short prompt and actual result.
Remove abandoned setup, permission dialogs and idle waits. Accelerate selection
and typing segments by about 1.5–3× using the reviewed cut list's `speed` field.
Use a five-second context illustration labelled **agent wait trimmed**. It must
be generated from verified session evidence, use the actual attachment labels
and explain what was captured versus what the agent read with its own tools.

Never substitute an agent response, source mutation or successful capture.
Record cut ranges and speeds privately. Keep account chrome, unrelated windows,
local user paths and private document identifiers out of every exported frame.
Decode and OCR all final MP4/GIF/poster frames, review the edited sequences and
metadata, then update the checksum manifest for those exact bytes. Publish only
the reviewed assets; raw sessions, profiles, receipts and recordings stay private.

Write manual control commands to a `.tmp` file, then rename it to `.json` so the
recorder sees a complete command. It also tolerates partial writes and persists
successful frame timestamps separately. If a verification step needs a separate
take, retain the same completed session and document identity, identify the
additional recording in the cut list and label it on screen.
