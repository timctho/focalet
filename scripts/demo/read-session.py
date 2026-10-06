#!/usr/bin/env python3
"""Read only the explicitly identified demo chat into private recording evidence."""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading


def demo_identity(profile):
    prepared = json.loads((profile / "demo-identity.json").read_text())
    binding = json.loads((profile / "binding.json").read_text())
    # An empty setup thread may be replaced when the UI submits its first turn.
    # Follow only this private profile's binding, on its exact runtime/workspace.
    if (
        binding["runtimeTargetId"] != prepared["runtimeTargetId"]
        or binding["cwd"] != prepared["workspace"]
    ):
        raise ValueError("The profile no longer identifies the prepared demo workspace")
    return dict(prepared, sessionId=binding["sessionId"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Use a new private evidence file")
    identity = demo_identity(args.profile)
    environment = dict(
        os.environ, **json.loads((args.profile / "demo-environment.json").read_text())
    )
    executable = args.package / (
        "focalet-core-host.exe" if os.name == "nt" else "focalet-core-host"
    )
    process = subprocess.Popen(
        [str(executable)],
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
    )
    replies = queue.Queue()

    def read():
        for line in process.stdout:
            replies.put(json.loads(line))
        replies.put(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    sequence = 0

    def request(operation, payload=None):
        nonlocal sequence
        sequence += 1
        message_id = str(sequence)
        process.stdin.write(
            json.dumps(
                {
                    "id": message_id,
                    "protocolVersion": 1,
                    "operation": operation,
                    "payload": payload or {},
                }
            )
            + "\n"
        )
        process.stdin.flush()
        while True:
            value = replies.get(timeout=60)
            if value is None:
                raise RuntimeError("Demo runtime stopped before returning evidence")
            if value.get("id") == message_id:
                if not value["ok"]:
                    diagnostic = args.output.with_name(
                        "private-session-read-error.json"
                    )
                    diagnostic.write_text(json.dumps(value.get("error")))
                    os.chmod(diagnostic, 0o600)
                    raise RuntimeError("Could not read the exact demo session")
                return value["result"]

    try:
        request("core.initialize")
        request("runtime.discover")
        result = request(
            "runtime.connect",
            {
                "runtimeTargetId": identity["runtimeTargetId"],
                "preferredSessionId": identity["sessionId"],
                "cwd": identity["workspace"],
            },
        )
        if result["sessionId"] != identity["sessionId"]:
            raise RuntimeError("Refusing evidence from a different session")
        session = request(
            "session.read",
            {
                "runtimeTargetId": identity["runtimeTargetId"],
                "sessionId": identity["sessionId"],
            },
        )
        with args.output.open("x", encoding="utf-8") as output:
            os.chmod(args.output, 0o600)
            json.dump(session, output)
        request("core.shutdown")
        process.wait(timeout=10)
        print("Saved the exact demo session to private recording evidence.")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        process.stdin.close()
        reader.join(timeout=5)
        process.stdout.close()


if __name__ == "__main__":
    main()
