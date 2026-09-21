# First-run setup and three demos

Use Amazon shopping, latency investigation and interactive Sheets editing, in
that order. The difficult part is identifying the exact objects or context the
user means. Target roughly 25–40 seconds per edited clip, with quick gestures,
short prompts and readable results. The [gallery](../../docs/demos/README.md)
contains the reviewed recordings; this brief alone is not acceptance evidence.

| Case | Context that is expensive to describe | User action | Payoff |
| --- | --- | --- | --- |
| Amazon | Five similar products, exact variants, and misleading dual-monitor labels | One loose rectangle around a row of real listing cards | Agent checks every exact listing against an M1 Air's display limit |
| Dashboard | Which latency spike, time buckets, metric definition and query | Select only the spike interval | Agent receives the full executed query and selected points, then investigates the database |
| Sheets | Which rows should change while the rest stays intact | Frame the two tables and draw arrows to two rows | Only the marked table rows become pale yellow and bold |

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

## 3. Sheets: the drawing decides which rows change

Use the private synthetic [Event layout fixture](sheets/README.md), with the
existing navy budget and orange schedule. Capture both tables in one region.
Use the native **Arrow** tool to point to one body row in each table, then
press **Attach**. The actual annotated PNG must reach the agent with two marks.

Ask: **“Make only the table rows marked by arrows pale yellow and bold. Keep all
values and formulas, and leave the other cells alone.”**

Supply no row names, addresses or document URL in the prompt. The real agent
must use the drawing to identify the intended rows, inspect the captured
Google Sheet and edit it with its own browser tools. Do not apply the result
on the agent's behalf.

Retain a private visual review of the arrow endpoints and the corresponding
cell addresses. `sheets_drawing_proof.py` verifies the completed turn, native
annotation provenance, actual browser actions, and ordered authenticated XLSX
exports. Every marked cell must become pale yellow and bold; unmarked cells,
other tabs, values, formulas and the remaining layout must stay unchanged.
Show both arrows being drawn and both resulting rows. Label trimmed agent
waits; zoomed crops may improve readability without changing the recorded UI.

## First-run setup

`scripts/demo/record-setup-windows.ps1` starts the actual packaged app with a
fresh private settings profile. Select an installed, already authenticated
agent in **Welcome to Zommi**, then choose **Connect and continue**. The recorder
requires persisted setup completion and a real runtime/session binding.
It does not seed a chat or generate an agent response. Capture the ready
composer, crop account/workspace details, and keep the raw profile private.
The published example uses Codex; the README lists all supported agents beside it.

## Editing and review

Keep the successful selection, attachment, short prompt and actual result.
Remove abandoned setup, permission dialogs and idle waits. Accelerate selection
and typing segments by about 1.5–3× using the reviewed cut list's `speed` field.
The Amazon and dashboard clips use a five-second context illustration labelled
**agent wait trimmed**. It must
be generated from verified session evidence, use the actual attachment labels
and explain what was captured versus what the agent read with its own tools.

Never substitute an agent response, source mutation or successful capture.
Record cut ranges and speeds privately. Keep account chrome, unrelated windows,
local user paths and private document identifiers out of every exported frame.
Decode and OCR all final MP4/GIF/WebP frames, review the edited sequences and
metadata, then update the checksum manifest for those exact bytes. Publish only
the reviewed assets; raw sessions, profiles, receipts and recordings stay private.

Write manual control commands to a `.tmp` file, then rename it to `.json` so the
recorder sees a complete command. It also tolerates partial writes and persists
successful frame timestamps separately. If a verification step needs a separate
take, retain the same completed session and document identity, identify the
additional recording in the cut list and label it on screen.
