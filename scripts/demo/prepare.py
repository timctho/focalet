#!/usr/bin/env python3
"""Create an empty Zommi profile connected to a real, already installed agent.

No model prompts are sent here. Agent credentials stay in the agent's home.
The profile and bindings are local recording inputs and must never be published.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument(
        "--workspace",
        required=True,
        help="Empty workspace in the selected runtime host",
    )
    parser.add_argument(
        "--agent-executable",
        help="Explicit real Codex CLI for the recording",
    )
    parser.add_argument(
        "--wsl-distribution", help="WSL distribution hosting --agent-executable"
    )
    parser.add_argument(
        "--browser-details",
        action="store_true",
        help="Enable the real Windows browser context provider for this demo profile",
    )
    parser.add_argument("--runtime-target-id", help="Use this exact discovered runtime")
    args = parser.parse_args()
    if args.wsl_distribution and (os.name != "nt" or not args.agent_executable):
        parser.error("--wsl-distribution requires Windows and --agent-executable")
    args.profile.mkdir(parents=True, exist_ok=False)
    settings = args.profile / ("Zommi" if os.name == "nt" else "config/zommi")
    settings.mkdir(parents=True)
    environment = dict(
        os.environ,
        APPDATA=str(args.profile),
        LOCALAPPDATA=str(args.profile),
        ZOMMI_CORE_STATE_PATH=str(args.profile / "binding.json"),
        ZOMMI_RUNTIME_OVERRIDES_PATH=str(args.profile / "overrides.json"),
        ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(args.profile / "targets.json"),
    )
    # A recording is a real app session, not one of the contract-test fixtures.
    for key in list(environment):
        if key.startswith("ZOMMI_FAKE_") or key == "ZOMMI_RUNTIME_DISCOVERY_MODE":
            del environment[key]
    environment.update(
        XDG_CONFIG_HOME=str(args.profile / "config"),
        XDG_STATE_HOME=str(args.profile / "state"),
        XDG_CACHE_HOME=str(args.profile / "cache"),
    )
    if args.wsl_distribution:
        (args.profile / "overrides.json").write_text(
            json.dumps([{
                "id": "demo-codex",
                "adapterId": "codex-app-server",
                "executablePath": args.agent_executable,
                "executionHost": {
                    "id": "wsl:" + args.wsl_distribution.lower(),
                    "kind": "wsl",
                    "platform": "linux",
                    "displayName": "WSL · " + args.wsl_distribution,
                    "isDefault": False,
                    "name": args.wsl_distribution,
                },
            }]),
            encoding="utf-8",
        )
    elif args.agent_executable:
        environment.update(
            ZOMMI_CODEX_COMMAND=args.agent_executable,
            ZOMMI_RUNTIME_DISCOVERY_MODE="configured-only",
        )
    core_name = "zommi-core-host.exe" if os.name == "nt" else "zommi-core-host"
    core = subprocess.Popen(
        [str(args.package / core_name)],
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
    )
    messages = queue.Queue()

    def read():
        for line in core.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    sequence = 0

    def request(operation, payload=None):
        nonlocal sequence
        sequence += 1
        identity = str(sequence)
        core.stdin.write(
            json.dumps(
                {
                    "id": identity,
                    "protocolVersion": 1,
                    "operation": operation,
                    "payload": payload or {},
                }
            )
            + "\n"
        )
        core.stdin.flush()
        while True:
            value = messages.get(timeout=60)
            if value is None:
                raise RuntimeError("The runtime host closed before answering.")
            if value.get("id") == identity:
                if not value["ok"]:
                    (args.profile / "private-error.json").write_text(
                        json.dumps(value["error"]), encoding="utf-8"
                    )
                    raise RuntimeError(
                        "The selected real runtime could not prepare the demo chat."
                    )
                return value["result"]

    try:
        request("core.initialize")
        targets = request("runtime.discover")["targets"]
        candidates = [
            t
            for t in targets
            if t["adapterId"] == "codex-app-server" and t["status"] == "detected"
        ]
        if args.runtime_target_id:
            candidates = [t for t in candidates if t["id"] == args.runtime_target_id]
        elif args.wsl_distribution:
            candidates = [
                t for t in candidates
                if t["executionHost"].get("name") == args.wsl_distribution
                and t["executablePath"] == args.agent_executable
            ]
        elif os.name == "nt" and args.workspace.startswith("/"):
            candidates = [t for t in candidates if t["executionHost"]["kind"] == "wsl"]
        candidates.sort(key=lambda t: not t["executionHost"].get("isDefault"))
        if not candidates:
            raise RuntimeError(
                "An authenticated Codex installation is required for this recording."
            )
        target = candidates[0]
        # No preferred session: create a new chat in the empty sample workspace.
        connected = request(
            "runtime.connect", {"runtimeTargetId": target["id"], "cwd": args.workspace}
        )
        (settings / "settings.json").write_text(
            json.dumps(
                {
                    "runtimeSetupCompleted": True,
                    "themeMode": "light",
                    "themeColor": "ocean",
                    "chatFontSize": 14,
                    "windowSize": "standard",
                    "browserPageDetails": args.browser_details,
                }
            ),
            encoding="utf-8",
        )
        (args.profile / "demo-environment.json").write_text(
            json.dumps(
                {
                    key: environment[key]
                    for key in (
                        "APPDATA",
                        "LOCALAPPDATA",
                        "ZOMMI_CORE_STATE_PATH",
                        "ZOMMI_RUNTIME_OVERRIDES_PATH",
                        "ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH",
                        "XDG_CONFIG_HOME",
                        "XDG_STATE_HOME",
                        "XDG_CACHE_HOME",
                        *(
                            ["ZOMMI_CODEX_COMMAND", "ZOMMI_RUNTIME_DISCOVERY_MODE"]
                            if args.agent_executable and not args.wsl_distribution
                            else []
                        ),
                    )
                }
            ),
            encoding="utf-8",
        )
        (args.profile / "demo-identity.json").write_text(
            json.dumps(
                {
                    "runtimeTargetId": target["id"],
                    "sessionId": connected["sessionId"],
                    "workspace": args.workspace,
                }
            ),
            encoding="utf-8",
        )
        print(
            "Prepared a fresh real-agent chat. Local profile and bindings are not public demo assets."
        )
        request("core.shutdown")
        core.wait(timeout=10)
    finally:
        if core.poll() is None:
            core.kill()
            core.wait(timeout=10)
        core.stdin.close()
        reader.join(timeout=5)
        core.stdout.close()


if __name__ == "__main__":
    main()
