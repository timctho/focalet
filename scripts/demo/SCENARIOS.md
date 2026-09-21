# First-run setup and three demos

Use Amazon shopping, latency investigation and interactive Sheets editing, in
that order. The difficult part is identifying the exact objects or context the
user means. Target roughly 25–45 seconds per edited clip, with quick gestures,
short prompts and readable results. The [gallery](../../docs/demos/README.md)
contains the reviewed recordings; this brief alone is not acceptance evidence.

| Case | Context that is expensive to describe | User action | Payoff |
| --- | --- | --- | --- |
| Amazon | Five similar products, exact variants, and misleading dual-monitor labels | One loose rectangle around a row of real listing cards | Agent checks every exact listing against an M1 Air's display limit |
| Dashboard | Which latency spike, time buckets, metric definition and query | Select only the spike interval | Agent receives the full executed query and selected points, then investigates the database |
| Sheets | Two groups spanning three tables, their destinations, and a crossed-out exception | Use Pen loops, connections and a cross-out in one native selection | Agent builds two linked quotes and only the connected quote recalculates |

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

## 3. Sheets: the sketch defines two quotes

Use the private synthetic [Quote builder fixture](sheets/README.md). Capture
all three source tables and both quote boxes in one region. Use native **Pen**
strokes for the loops, connections, arrowheads and cross-out, then **Attach**.

Ask: **“Turn my sketch into the two quotes. Each loop feeds the box it points to;
skip the crossed-out option. Link to source cells and calculate subtotal, tax
and total. Leave source data alone.”**

Supply no item names, addresses or document URL in the prompt. The actual agent
must interpret the sketched groups and exception, read the Sheet and create the
formulas with its own browser tools. Do not apply the result on its behalf.
Keep the fixture guide and answer key out of its empty workspace.

Retain a private visual review of the native attachment. The published take uses
17 Pen strokes, with coral connections to Plan A and blue connections to Plan B.
`sheets_quote_proof.py` checks the completed turn, native annotation provenance,
actual browser actions, six formula cells and four ordered whole-workbook XLSX
exports. The exports cover baseline, completed edit, source-price change and
restoration. Verify the marked source references, correct taxes, exclusion and
that only the connected quote changes. Other tabs, source data and formatting
outside the quote amounts must remain unchanged; confirm **Saved to Drive**.

Show the native strokes and end the public clip on the agent’s completed reply.
Keep the subsequent source-price change and restoration in private verification
evidence only. Label trimmed agent waits; zoomed crops may improve readability without changing the recorded UI.

## First-run setup

`scripts/demo/record-setup-windows.ps1` starts the actual packaged app with a
fresh private settings profile in **Ocean**. Show all installed agents; select an
agent in **Welcome to Zommi**, then choose **Connect and continue**. The recorder
requires persisted setup completion and a real runtime/session binding.
It does not seed a chat or generate an agent response. Open the model picker,
show both Codex and OpenCode model choices, then record the **entire ready app
window**, including the sidebar, header and composer. Use a clean actual runtime profile so personal
chat titles and workspace paths never need to be cropped from the ending. Keep
raw profiles private. The README lists supported agents and model families next
to the accelerated selection video. Do not copy credentials into demo profiles.

## Editing and review

Use Ocean for Zommi and explanatory graphics. The current Amazon and dashboard
edits retain the original native selections and reopen the same completed
sessions in Ocean for the conversation views. Disclose this in the recording
notes; do not simulate a new turn or alter the saved reply.

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
