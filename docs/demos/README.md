# See what you can stop describing

Start with a real first launch, then see three native Windows examples:
a row of similar products, one spike inside a dashboard, and a freehand sketch
that defines two spreadsheet quotes across three tables. Previews play automatically;
click them to open the clearer MP4.

## First launch: connect an agent and select a model

**Welcome to Zommi** shows the installed Codex, OpenCode, Pi, Hermes, OpenClaw
and Claude CLI agents. Connect Codex and choose a model, then use **New agent**
to open OpenCode and select one of its models. Selection is accelerated; the
ending shows
the full Zommi window with its sidebar, selected model and ready composer.

This take uses the real installed Codex and OpenCode runtimes with isolated
demo histories and their default model catalogs. No credentials are copied
into the demo profiles. The app persists setup completion and binds real empty
sessions.
Model availability in your installation depends on your agent, providers and
account. No agent reply is simulated.

[![Choose among six agents, select Codex and OpenCode models, and see the complete app](setup-preview.webp)](setup.mp4)

[Watch setup · 15 seconds](setup.mp4) · [Agents and model families](../../README.md#connect-your-agent-and-choose-a-model) · [Installation guide](../install.md)

## 1. Amazon: one box around all the candidates

On the real listing grid, select the whole row once. Ask:
**“Which of these would let my M1 MacBook Air run two independent monitors?
Check the exact listings. Keep the comparison short and link the sources.”**

The single native attachment retains all five product links. The agent reads
every exact listing and checks Apple's display limit. Its sourced comparison
finds that **none of the five supports two independent external displays on the
M1 Air**, despite their dual-HDMI descriptions. No purchase is made.

[![Select five Amazon candidates in one rectangle and receive a sourced compatibility comparison](amazon-preview.webp)](amazon.mp4)

[Watch · 29 seconds](amazon.mp4) · [View the comparison](amazon-poster.webp)

## 2. Dashboard: just this latency spike

Select only the spike's interval, leaving Query Inspector outside the rectangle.
Ask: **“Why did latency spike here? Check the underlying query and source data.
Give me the cause and strongest evidence in 3 short bullets.”**

One native attachment carries the full executed SQL and the **14:30, 14:35 and
14:40 UTC** points. The agent runs the query and investigates the synthetic
source records: p95 rises **256 → 1,450 ms** after an inventory-pool reduction in
one region; recovery follows restoration of that setting. Volume and comparison
traffic stay steady. The source database and query remain unchanged.

[![Select only a latency spike, then read an investigation grounded in its full query and source data](dashboard-preview.webp)](dashboard.mp4)

[Watch · 25 seconds](dashboard.mp4) · [View the analysis](dashboard-poster.webp)

## 3. Sheets: a sketch becomes two linked quotes

Select the **Quote builder** sheet, then use the native **Pen** to loop rows,
connect them to two quote boxes, and cross out an option inside one loop. Ask:
**“Turn my sketch into the two quotes. Each loop feeds the box it points to;
skip the crossed-out option. Link to source cells and calculate subtotal, tax
and total. Leave source data alone.”**

The coral loops combine **Lighting kit + Coffee** in Plan A. The blue loops
combine **Display + Signage + Snack box** in Plan B, excluding the crossed-out
**Staff meal**. The agent has to trace connections across three source tables,
handle the exception and apply the different tax rates. No item names, cell
addresses or document URL are supplied in the prompt.

[![Native freehand loops, connections and a crossed-out option become two linked quotes](sheets-preview.webp)](sheets.mp4)

[Watch the sketch demo · 29 seconds](sheets.mp4) · [View the result](sheets-poster.webp)

The single actual attachment contains **17 Pen strokes**. The agent writes six
formulas and displays the quote amounts with two decimal places. Plan A totals
**564.80**; Plan B totals **814.80**. In a separate, off-clip verification, changing
the
Display unit price **180 → 230** changes only Plan B, to **922.80**. Restoring 180
restores its original total.

Whole-workbook exports verify the six output cells, source references, the
excluded option, recalculation and restoration. Source values/formulas,
formatting outside the output amounts, layout and other tabs stay unchanged.
The live page confirms **Saved to Drive**. The temporary source-price change is
a maintainer verification after the agent's completed turn.

## What was recorded

Recorded September 20–21, 2026 with the native Windows app. Setup uses Codex
and OpenCode; the three task demos use Codex.
Amazon uses signed-out public product pages; listings and availability can
change. The dashboard and private Google Sheet contain synthetic data.

Selections, prompts, agent replies and sheet edits are real. The edited clips
shorten waits and accelerate gestures. All four demos use Ocean for Zommi and
their explanatory graphics. Amazon and dashboard pair the original native
selections with a new recording of the same completed conversations reopened
in Ocean; no new request or agent reply is generated for these views. They include
five-second labelled context illustrations; the drawing uses native footage
with explanatory captions and zoomed crops. Setup retains the full app window
after the model is selected. Results retain reading time. There is no audio
or scripted agent response. Discarded capture attempts are omitted.

Sheets uses one annotated selection and one request. The selection, freehand strokes and
completed reply belong to the same native take and agent session. The clip ends
on that reply; the later price-change and restoration checks are omitted.

The sample dashboard explicitly exposes its executed SQL through the chart's
standard accessibility description. Zommi captures that description and the
spatially selected points; Query Inspector is not selected. This demonstrates
an application that exposes query context, not recovery of arbitrary hidden
queries. The agent already has access to the sample database workspace.

The Amazon grid's DOM traversal is truncated, but all five candidate links are
retained; the agent reads full product details with browser tools. Sheets uses
native Windows accessibility, retaining document identity with a truncated
traversal; the agent reads and edits the actual cells through its browser tools.
Zommi supplies context, while the existing agent supplies the tools and access.

All final MP4/GIF/WebP frames are decoded and scanned with OCR. The lossless
WebP previews preserve the reviewed GIF pixels and timeline at 960px and 8fps. Edited
sequences and media metadata are reviewed, and the [manifest](manifest.json)
records exact published hashes and the primary Windows recording build. Amazon
and dashboard selections were captured on `e21bf1c`; their Ocean conversation
views and the setup demo were recorded on `9701793`. Sheets was recorded on
`9819001`. Raw captures, profiles, session transcripts, workbook receipts and OCR text remain
private. The source sheet URL is not published.

## Reproduce and verify

See the [recording brief](../../scripts/demo/SCENARIOS.md),
[latency storyboard](../../scripts/demo/DASHBOARD-STORYBOARD.md), and
[sheet fixture](../../scripts/demo/sheets/README.md). Use a fresh recording
profile and verify browser access before recording. Capture through the native
app, inspect the actual attachment source, and keep account chrome out of crops.

Proof guards require completed agent sessions, real tool activity and source
readbacks before generating the illustrations. The dashboard guard also rejects
missing query metadata or points outside the selected interval. The Sheets guard
checks native Pen provenance, visually reviewed groupings and exclusion, the
six formula cells, live recalculation/restoration and preservation of source
cells, formatting and other tabs. A decorative drawing, hardcoded totals or an
edit outside the requested outputs fails this scenario.
Timing markers alone do not prove that a capture or edit succeeded.

```sh
python3 scripts/demo/review-export.py \
  /private/output/demo.mp4 /private/output/demo.gif /private/output/demo-poster.webp \
  --output /private/output/review \
  --forbid-file /private/account-and-project-names.txt
python3 -m unittest discover -s tests -p 'test_demo*.py' -q
python3 scripts/verify_demo_assets.py
```

Keep the forbidden-name list and OCR output private. Combine OCR with visual
and source review, and update the manifest only after the exact bytes pass.
