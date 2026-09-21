#!/usr/bin/env python3
"""Interactive terminal fixture for Rust PTY compatibility tests."""

import os
import sys

# The runtime wire protocol is UTF-8, including on Windows redirected pipes.
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")


request_log = os.environ.get("ZOMMI_FAKE_REQUEST_LOG")
if os.environ.get("ZOMMI_FAKE_TRUST_PROMPT") == "1":
    sys.stdout.write(
        "Do you trust the files in this folder?\r\n"
        "❯ 1. Yes, proceed\r\n"
        "  2. No, exit\r\n"
        "Enter to confirm · Esc to exit\r\n"
    )
else:
    sys.stdout.write("> ")
sys.stdout.flush()

for line in sys.stdin:
    if request_log:
        with open(request_log, "a", encoding="utf-8") as stream:
            stream.write(line)
    sys.stdout.write("\r\nfixture terminal answer\r\n> ")
    sys.stdout.flush()
