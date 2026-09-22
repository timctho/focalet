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

Use the short sketch prompt in the [recording brief](../README.md). Do not put
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
restoration as private verification evidence, and verify **Saved to Drive**.
End the public demo on the agent’s completed response, before these checks.
`sheets_quote_proof.verify` consumes
the actual completed session, all four ordered exports and the visually reviewed
row groups. It checks native Pen provenance, actual browser edits, linked
formulas, exclusion, recalculation and source/layout/other-tab preservation.
Review every final media frame before publishing; all raw exports, account
chrome, document identifiers and session evidence stay private.
