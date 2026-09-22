# Demo recordings

The [README](../../README.md#see-it-in-action) shows the animated previews.
These silent recordings use the native Windows app in Ocean.

| Recording | Video | Still |
| --- | --- | --- |
| First launch: six agent options, Codex and OpenCode models, full app | [11 seconds](setup.mp4) | [Ready app](setup-poster.webp) |
| Amazon: three separate selections and a sourced compatibility comparison | [16 seconds](amazon.mp4) | [Comparison](amazon-poster.webp) |
| Dashboard: selected latency interval, exposed SQL and source investigation | [25 seconds](dashboard.mp4) | [Analysis](dashboard-poster.webp) |
| Sheets: freehand groups and an exclusion become two linked quotes | [29 seconds](sheets.mp4) | [Quotes](sheets-poster.webp) |

## Recording notes

Selections, agent replies and sheet edits are real. Setup uses Codex and
OpenCode; the task demos use Codex. The dashboard and sheet contain synthetic
data. Amazon uses signed-out public listings, whose availability can change.

Clips shorten waits and accelerate gestures. Amazon's comparison stays visible
for three seconds. Amazon and dashboard include labelled context illustrations
of three and five seconds respectively. The dashboard pairs its original
selection with its completed conversation reopened in Ocean. Sheets uses
native drawing footage and ends on the agent's response; subsequent
recalculation checks are outside the clip.

The sample chart exposes its executed SQL through accessibility metadata.
Zommi captures that description and the selected points; the agent already
has access to the sample database. This does not demonstrate recovery of
hidden queries in arbitrary dashboards. Amazon's attachments each carry one
product link. Sheets retains document identity through Windows accessibility;
the agent reads and edits cells with its own browser tools. Zommi supplies
context, and the agent supplies tools and access.

The [manifest](manifest.json) records source revisions, media metadata and
hashes. Raw captures, profiles, transcripts, workbook exports and OCR results
remain outside the repository.

## Reproduce and verify

Use the [recording guide](../../scripts/demo/README.md) and synthetic fixtures
with a fresh recording profile. Review the actual native attachments and
completed agent sessions before editing. For Sheets, compare whole-workbook
exports, verify recalculation and restoration, preserve unrelated cells and
formatting, and confirm **Saved to Drive**.

Review every exported frame visually and with OCR. Keep the account/project
name list and OCR output private:

```sh
python3 scripts/demo/review-export.py \
  /private/output/demo.mp4 /private/output/demo.gif /private/output/demo-poster.webp \
  --output /private/output/review \
  --forbid-file /private/account-and-project-names.txt
python3 -m unittest discover -s tests -p 'test_demo*.py' -q
python3 scripts/verify_demo_assets.py
```

Update the manifest only after the exact exported files pass review.
