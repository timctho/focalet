"""Require the latest main push checks for the exact release revision."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import time


def check_state(runs: list[dict], commit: str) -> str:
    matching = [run for run in runs if run.get("head_sha") == commit
                and run.get("head_branch") == "main" and run.get("event") == "push"]
    if not matching:
        return "pending"
    latest = max(matching, key=lambda run: run["id"])
    if latest.get("status") != "completed":
        return "pending"
    return "success" if latest.get("conclusion") == "success" else "failure"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repository) or not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("Expected owner/repository and a full commit SHA.")
    deadline = time.monotonic() + args.timeout
    endpoint = (f"repos/{args.repository}/actions/workflows/checks.yml/runs"
                f"?head_sha={args.commit}&event=push&per_page=100")
    while True:
        response = json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))
        state = check_state(response["workflow_runs"], args.commit)
        if state == "success":
            print(f"Full main checks passed for {args.commit}.")
            return
        if state == "failure":
            raise SystemExit("Main checks failed, were cancelled, or were skipped; publication is blocked.")
        if time.monotonic() >= deadline:
            raise SystemExit("Timed out waiting for main checks; publication is blocked.")
        print("Waiting for this revision's main checks...", flush=True)
        time.sleep(min(15, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    main()
