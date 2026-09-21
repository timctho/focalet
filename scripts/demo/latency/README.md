# Synthetic latency investigation

Copy this directory into a fresh agent workspace and run `python3 app.py`.
The dashboard executes `latency.sql` against a local `demo.sqlite` on each load.
It displays /checkout p95 latency by five-minute UTC bucket, across both regions.

The chart exposes the exact executed SQL in its standard `aria-description`.
Each SVG point exposes time, latency and request count. This is an accessible
sample application, not a claim that arbitrary dashboards expose hidden queries.
Zommi's existing native browser provider captures an intersecting chart object's
description and spatially selected point labels. The agent must use its own
workspace tools to analyze the database; the metadata contains no diagnosis.

The fixture seeds two routes, two regions and 12 buckets. A sample inventory pool
setting changes from 20 to 2 in us-west-2 at 14:28, then returns to 20 at 14:43.
Checkout inventory time rises by 1,200 ms during the three affected buckets.
Volume, payment time, queue time and east-region traffic remain steady. The
executed global p95 is 256 ms before/after and 1,450 ms during the spike.

This maintainer explanation stays outside the recording workspace. Copy only
`app.py`, `index.html` and `latency.sql`; let the agent investigate source records.
The server reads query results with a read-only SQLite connection. Keep all
source files unchanged during the analysis take and verify their saved hashes.
