#!/usr/bin/env python3
"""Query-backed synthetic latency incident, with accessible chart metadata."""

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
    with sqlite3.connect(path) as db:
        db.executescript("""
            CREATE TABLE requests (
                id INTEGER PRIMARY KEY, minute TEXT NOT NULL,
                environment TEXT NOT NULL, route TEXT NOT NULL,
                region TEXT NOT NULL, release TEXT NOT NULL,
                duration_ms INTEGER NOT NULL, inventory_ms INTEGER NOT NULL,
                payment_ms INTEGER NOT NULL, queue_ms INTEGER NOT NULL,
                outcome TEXT NOT NULL
            );
            CREATE TABLE deployments (
                minute TEXT, region TEXT, release TEXT, setting TEXT,
                previous_value TEXT, new_value TEXT
            );
            INSERT INTO deployments VALUES
                ('14:28', 'us-west-2', '4.18', 'inventory_pool_size', '20', '2'),
                ('14:43', 'us-west-2', '4.18', 'inventory_pool_size', '2', '20');
        """)
        for bucket in range(12):
            for route in ("/checkout", "/cart"):
                for index in range(500):
                    region = "us-west-2" if index % 2 else "us-east-1"
                    spike = 6 <= bucket <= 8 and region == "us-west-2"
                    release = (
                        "4.18" if bucket >= 6 and region == "us-west-2" else "4.17"
                    )
                    inventory = 70 + index % 40
                    if spike and route == "/checkout":
                        inventory += 1200
                    payment, queue = 90 + index % 20, 10 + index % 5
                    duration = inventory + payment + queue + 30
                    db.execute(
                        "INSERT INTO requests VALUES (NULL,?,?,?,?,?,?,?,?,?,?)",
                        (
                            f"14:{bucket * 5:02}",
                            "production",
                            route,
                            region,
                            release,
                            duration,
                            inventory,
                            payment,
                            queue,
                            "ok",
                        ),
                    )


def dashboard(directory=ROOT):
    query = (directory / "latency.sql").read_text()
    with sqlite3.connect(
        (directory / "demo.sqlite").as_uri() + "?mode=ro", uri=True
    ) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        rows = [dict(row) for row in db.execute(query)]
    return {"synthetic": True, "query": query, "rows": rows}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/api/dashboard":
            content, mime = (
                json.dumps(dashboard(self.server.directory)).encode(),
                "application/json",
            )
        elif path in ("/", "/index.html"):
            content, mime = (
                self.server.directory / "index.html"
            ).read_bytes(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
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
    print(f"Latency sample: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
