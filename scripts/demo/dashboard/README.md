# Checkout health sample

This is an isolated demo workspace. All data is synthetic. No customer records,
accounts, keys or external services are used.

Run `python3 app.py` and open `http://127.0.0.1:8765`. The first run creates
`demo.sqlite`. Each refresh executes `error-rate.sql` and `failed-checkouts.sql`;
editing either query changes the chart from actual query results.

The intended measure of checkout error rate is **failed checkouts / all
checkouts**, with one observation per checkout. `checkout_events` records
telemetry events associated with a checkout. Read the database to investigate
what the displayed queries currently count.

For an agent-assisted demonstration, work only in this copied sample directory.
The user may ask you to diagnose and fix the dashboard. Do not use personal
files, accounts or external systems. Keep the final explanation short and about
the data; do not include personal greetings or local account paths.
