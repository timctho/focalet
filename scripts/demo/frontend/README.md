# Frontend: redesign a chart from a sketch

The [revenue dashboard](app/) is a runnable local web app with example data.
Its single bar chart shows monthly totals but hides the channel breakdown.
The redesign splits it into stacked channels on the left and a monthly revenue
trend on the right, using the same values and period controls.

Copy `app/` into a disposable workspace and serve it with
`python3 -m http.server 8882`. Connect a real agent to that workspace. Keep the
baseline here unchanged; the agent edits only the disposable copy. Use a browser
viewport around 900 CSS pixels wide and select Jan–Jun.

Use the actual Focalet app in Ocean beside the source browser. Enable authorized
browser context and select the revenue panel. Use Pen to draw two panels,
stacked bars on the left, and a trend line on the right. Review the attachment's
Details before sending:

> Same six months: stacked channels left, revenue trend right.

The prompt supplies no filenames, selectors or implementation. Verify the actual
handoff contains the chart identity, aligned bounds, monthly totals, channel
values, the data link and native annotations. The example chart exposes its
values through accessible labels; this does not establish hidden-data extraction
for arbitrary charts. Keep the exact agent session and source diff privately.

After the agent finishes, refresh the source. Verify that the left chart stacks
all three channels, the right chart plots monthly totals, both update when the
period changes, and the values match the unchanged source data. Check hover or
keyboard details, Refresh, other panels and a narrower viewport. Do not apply
the result on the agent's behalf.

Show the actual selection, context review, short prompt and refreshed result.
Use a close view of the graph when it changes, then compare actual before/after
frames from that same recording. Keep text brief and label trimmed agent waits.

Use `record-windows.ps1 -Scene frontend -Manual -BrowserEndpoint <endpoint>`.
For an explicitly configured WSL CLI, supply `-AgentExecutable <absolute path>`
and `-WslDistribution <distribution>`. Keep profiles, raw frames and session
evidence outside the repository and follow the [media review](../README.md#editing-and-review).
