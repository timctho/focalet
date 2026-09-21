#!/usr/bin/env python3
"""Synthetic, editable dashboard for an actual Zommi capture-to-fix recording.

The charts execute the SQL files against SQLite on each refresh. There is no
precomputed 'fixed' scene; an agent has to change the query to change the graph.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent


def seed(path):
    if path.exists():
        return
    with sqlite3.connect(path) as database:
        database.executescript("""
            CREATE TABLE checkouts (
                id INTEGER PRIMARY KEY, minute TEXT NOT NULL,
                outcome TEXT NOT NULL CHECK(outcome IN ('paid', 'failed'))
            );
            CREATE TABLE checkout_events (
                checkout_id INTEGER NOT NULL REFERENCES checkouts(id),
                event_type TEXT NOT NULL
            );
        """)
        identity = 0
        for bucket in range(12):
            minute = f"14:{bucket * 5:02}"
            for index in range(1000):
                identity += 1
                outcome = "failed" if index < 20 else "paid"
                database.execute(
                    "INSERT INTO checkouts VALUES (?, ?, ?)",
                    (identity, minute, outcome),
                )
                events = ["checkout_finished"]
                if bucket >= 6 and outcome == "failed":
                    events += ["retry_logged"] * 5
                database.executemany(
                    "INSERT INTO checkout_events VALUES (?, ?)",
                    [(identity, event) for event in events],
                )


def dashboard(directory=ROOT):
    panels = []
    with sqlite3.connect(
        (directory / "demo.sqlite").as_uri() + "?mode=ro", uri=True
    ) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        for name in ("error-rate", "failed-checkouts"):
            sql = (directory / f"{name}.sql").read_text()
            panels.append(
                {
                    "id": name,
                    "query": sql,
                    "rows": [dict(row) for row in db.execute(sql)],
                }
            )
    return {"synthetic": True, "panels": panels}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/api/dashboard":
            try:
                content = json.dumps(dashboard(self.server.directory)).encode()
                status, mime = 200, "application/json"
            except (sqlite3.Error, OSError) as error:
                content = json.dumps({"error": str(error)}).encode()
                status, mime = 500, "application/json"
        elif path in ("/", "/index.html"):
            content = (self.server.directory / "index.html").read_bytes()
            status, mime = 200, "text/html; charset=utf-8"
        else:
            content, status, mime = b"Not found", 404, "text/plain"
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--directory", type=Path, default=ROOT)
    args = parser.parse_args()
    directory = args.directory.resolve()
    seed(directory / "demo.sqlite")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.directory = directory
    print(f"Synthetic dashboard: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
