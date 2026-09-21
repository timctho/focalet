# Dashboard: identify the spike without explaining the dashboard

Use the [latency fixture](latency/README.md). The user selects just the elevated
14:30, 14:35 and 14:40 points, then asks why latency spiked. The query editor is
visible below the chart but is not selected.

## Prepare

Copy `scripts/demo/latency/` to a fresh workspace on the agent's host and run
`python3 app.py`. The server creates 12,000 synthetic request records and runs
`latency.sql` against SQLite. Save SHA-256 hashes for `demo.sqlite`, `latency.sql`
and `index.html` in the take's private `baseline.json` before sending the prompt.

Use a 2400×1600 Windows desktop and the native recording package:

```powershell
./scripts/demo/record-windows.ps1 `
  -PackageDirectory C:\path\to\zommi-windows-x64 `
  -OutputDirectory C:\path\to\private-take `
  -Scene dashboard -Workspace /tmp/zommi-demo-latency -Manual
```

Use manual recording for this single-region scenario. The legacy automatic
three-region routine still belongs to the older error-rate regression fixture.
Inspect the real desktop, position the chart and app, then create `record.ready`.
Use the recorder's ordered control files to mark selection, submission and
response completion. Timing markers do not prove success.

## Record the handoff

Draw one quick rectangle covering only the elevated interval. Wait for the real
native selection event and check its source and alignment before submission.
Ask: “Why did latency spike here? Check the underlying query and source data.
Give me the cause and strongest evidence in 3 short bullets.”

The chart's standard `aria-description` contains the exact executed query. Its
point labels contain UTC timestamps, p95 values and request counts. These belong
to the observed chart; no answer or incident diagnosis is in the metadata. The
native capture should contain the intersecting chart object plus the three
selected points, without capturing the textarea.

Let the actual agent run the query, inspect request components and compare
deployment records. Preserve the database and query. The expected investigation
finds an inventory-pool reduction in us-west-2, an extra 1,200 ms of inventory
latency, steady volume and unaffected comparison traffic. Restoring the pool
precedes recovery while the new release remains deployed.

## Verify and edit

After the turn completes, use `read-session.py` to save that exact profile's
bound session privately. Use `edit-story.py` with scene `dashboard`, the sample
`workspace`, reviewed source spans/crops/speeds and one flow insert. Its
`latency_proof.py` guard verifies the actual single image, complete captured SQL,
selected interval, real database tool activity and unchanged source hashes.

Keep the selection quick, accelerate typing, trim the investigation wait and
hold the completed answer long enough to read. The five-second illustration
explicitly says that the query comes from the chart's accessibility metadata.
Do not suggest all dashboard apps expose this information or that a crop grants
database access. The agent uses its existing workspace and tools.

Scan every exported MP4, GIF and poster frame with `review-export.py`, inspect
the edited sequence and verify metadata before replacing the gallery assets.
Run `python3 -m unittest discover -s tests -p 'test_demo*.py' -q` and
`python3 scripts/verify_demo_assets.py` against the final revision.
