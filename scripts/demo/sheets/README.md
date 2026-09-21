# Handdrawn quote builder

Create a new **Quote builder** tab in the private synthetic workbook and paste
`quote-builder.tsv` at A1. Leave existing tabs intact. Format A1:G19 at 12 pt;
use column widths 180, 45, 85, 55, 80, 105 and 105 pixels. Merge A1:D1 and F1:G1,
bold the headings and totals, give source headers light gray fills, Plan A a
light coral fill and Plan B a light blue fill. Format the six empty amounts as
currency; the agent may use two-decimal number formatting for its quote outputs.
Capture an XLSX baseline after preparation and verify pre-existing tabs against
a pre-preparation export.

Use one native selection of the whole layout. With **Pen only**, draw irregular
loops around Lighting kit and Coffee, connecting both to Plan A in coral. In
blue, loop Display, Signage, and the Snack box / Staff meal group; connect them
to Plan B and cross out Staff meal. The reviewed take has 17 strokes, including
freehand arrowheads. Do not substitute Arrow, Rectangle or Ellipse tools.

Use the short sketch prompt in the [recording brief](../SCENARIOS.md). Do not put
item names, cell addresses, the document URL, this guide or the expected result
in the prompt or the agent's empty workspace. Record the native selection,
strokes, attachment, actual agent request and completed browser edits.

Maintainer expectations, derived from the reviewed annotated attachment:

| Quote | Source rows | Output cells | Subtotal | Tax | Total |
| --- | --- | --- | ---: | ---: | ---: |
| A | 4, 17 | G4:G6 | 520 | 44.80 | 564.80 |
| B | 5, 11, 18; exclude 19 | G13:G15 | 750 | 64.80 | 814.80 |

After the agent completes, export the whole workbook. Change C5 from 180 to 230
in the live UI: Plan B must become 850 / 72.80 / 922.80 while Plan A stays fixed.
Export again, restore C5 to 180, and export once more. Record both the change and
restoration, and verify **Saved to Drive**. `sheets_quote_proof.verify` consumes
the actual completed session, all four ordered exports and the visually reviewed
row groups. It checks native Pen provenance, actual browser edits, linked
formulas, exclusion, recalculation and source/layout/other-tab preservation.
Review every final media frame before publishing; all raw exports, account
chrome, document identifiers and session evidence stay private.

## Earlier drawing-directed row emphasis

Use the private synthetic **Event layout** tab with the compact navy budget and
spacious orange schedule from the earlier layout take. Select both tables in
one native capture and draw two arrows to body rows. That earlier recording
points to A4:E4 and A15:E15; these addresses are maintainer verification inputs,
never part of the agent prompt or its empty capture workspace.

Ask only for the marked table rows to become pale yellow and bold, preserving
all other cells, values and formulas. Verify arrow endpoints in the actual
annotated image. Export the entire workbook before and after via its ordinary
authenticated XLSX export (browser fetch credentials `same-origin`, so the
signed download redirect does not carry cross-origin credentials).

Run `sheets_drawing_proof.py` against the completed real-agent session and these
readbacks. It rejects missing annotations, substitute target rows, edits outside
the marks, changed formulas/data and changes to other tabs. Also verify the
live page reports **Saved to Drive**, and visually inspect the final native
footage. Raw exports, URLs, agent sessions and reviewed target receipts stay
private.

## Earlier two-reference layout fixture

Create a private Google Sheet or add an **Event layout** tab to the disposable
sample workbook. Paste `event-overview.tsv` at A1, with formulas and numeric
values interpreted by Sheets. Start with default narrow columns and plain
formatting. The two synthetic blocks are deliberately cramped: **EVENT BUDGET**
at A1:E7 and **RUN OF SHOW** at A11:E17. Keep the spacer rows.

The capture workspace must not contain this maintainer guide, range addresses,
expected styles, or a hidden answer key. Use only the A/B prompt in the
[recording brief](../SCENARIOS.md), together with two loose native selections.
The real agent should map each reference to the correct block and apply its
separate instruction using its own browser tools.

Capture a private authenticated XLSX before and after the real edit, with the
source URL and observation time. Inspect the correct tab through workbook
relationships, not by assuming it is the first worksheet. Verify changed title
styles and readable column widths. A must be compact with navy headers; B must
have orange headers, taller body rows and larger text than A. Compare their
actual row heights, font sizes and colors; reject matching or swapped layouts.
Every value and formula must be unchanged; other tabs must also remain unchanged. Review the actual native before/after footage visually.

Use `sheets_layout_proof.py` with `scenario: contrasting-layouts` and
`sheetName: Event layout` in the private cut list. The result belongs to the
same native take and completed agent session.
Raw workbook receipts, document identifiers, sessions and recordings stay private.

## Historical formula fixture

The previous `event-budget.csv` and `sheets_proof.py` remain available for the
earlier two-turn formula/recalculation recording. They are not the current
published Sheets scenario.

### Event budget formula checks

Import `event-budget.csv` into a new private Google Sheet. Enable conversion of
text to numbers and formulas. Name the document **Event budget - Zommi sample**
and its tab **Event budget**. Format Discount as a percentage and Unit price,
Total, Deposit and Remaining as currency. Widen Item/Status and the headers so
the selection can retain their meaning. This is synthetic sample data.

The agent should discover the bug from the captured context and its own live
cell reads. Do not give it this answer key, the checks below, or a prompt with
cell addresses. The capture workspace should not contain this maintainer file.

### Before recording

Lighting is the correct example. Displays, Seating and Printing subtract a
fractional discount as a flat amount instead of applying a percentage. Cancelled
and Draft rows are deliberate exceptions and must be preserved. Remaining is
initially empty.

| Row | Initial total | Correct total | Deposit | Remaining after second turn |
| --- | ---: | ---: | ---: | ---: |
| Lighting | 270 | 270 | 100 | 170 |
| Displays | 599.9 | 540 | 0 | 540 |
| Seating | 799.85 | 680 | 100 | 580 |
| Old venue | 0 | 0 | 0 | empty |
| Printing | 89.9 | 81 | 50 | 31 |
| Extra stage | 630 | 630 | 0 | empty |

Confirm these initial values in Google Sheets after import. Capture the exact
document/tab identity, original grid/formulas and selected regions privately.
The agent must have working tools attached to that document before recording.

### Expected live edits

First turn: change the Total formulas for Displays, Seating and Printing to the
equivalent of `Quantity * Unit price * (1 - Discount)`. Leave all source values,
the correct Lighting formula, and Cancelled/Draft formulas intact.

Second turn: fill Remaining for the four Confirmed rows with `Total - Deposit`.
Leave Cancelled/Draft Remaining blank. Apply a greater-than-500 conditional
format to the Remaining cells, rather than hardcoded colors. Displays and
Seating should highlight; Lighting and Printing should not.

For the visible recalculation check, change the Displays deposit from 0 to 100:
its remaining balance becomes 440 and its highlight clears. Restore 0 and
confirm 540/highlight returns. This input change and restoration must appear in
the actual recording and be checked against the same document.

The public clip should show the changed cells, formulas and recalculation. Raw
before/after cell reads, browser tool receipts and the sheet URL stay private.
Preparing/importing this CSV is not proof of a completed interactive demo.
