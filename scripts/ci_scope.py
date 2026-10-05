"""Select product checks; shared and unknown changes require every native lane."""
from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT_DOCUMENTS = {"README.md", "CONTRIBUTING.md", "AGENTS.md", "SECURITY.md", "LICENSE", "THIRD_PARTY_NOTICES.md"}
DOCUMENT_SUFFIXES = {".md", ".png", ".webp", ".svg", ".gif", ".mp4", ".css"}


CAPTURE_PATHS = ("src/Zommi.CaptureTool/", "tests/clipboard-electron/")
DESKTOP_PATHS = ("src/Zommi.Flutter/", "crates/zommi-core/", "crates/zommi-core-host/", "tests/runtime-clis/")


def required_products(paths: list[str] | None) -> tuple[bool, bool]:
    """Return (desktop, capture); only known product-local changes skip a lane."""
    if not paths:
        return True, True
    desktop = capture = False
    for name in paths:
        path = PurePosixPath(name)
        if not path.parts or path.is_absolute() or ".." in path.parts:
            return True, True
        if name in ROOT_DOCUMENTS or (path.parts[0] == "docs" and path.suffix in DOCUMENT_SUFFIXES):
            continue
        if name.startswith(CAPTURE_PATHS) or name == "scripts/package-capture-tool.ps1":
            capture = True
        elif name.startswith(DESKTOP_PATHS):
            desktop = True
        else:
            # Includes shared capture, dependency/build configuration, workflow
            # policy and paths we do not yet recognize. Renames expose both paths.
            return True, True
    return desktop, capture


def requires_native(paths: list[str]) -> bool:
    return any(required_products(paths))


def changed_paths(event: dict, event_name: str) -> list[str] | None:
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
        head = event["pull_request"]["head"]["sha"]
        # The PR base may have advanced since the branch forked.
        diff_range = "..."
    elif event_name == "push":
        base, head = event.get("before", ""), event.get("after", "")
        diff_range = ".."
    else:
        return None
    if not all(re.fullmatch(r"[0-9a-f]{40}", ref) and ref != "0" * 40 for ref in (base, head)):
        return None
    try:
        output = subprocess.check_output([
            "git", "diff", "--name-only", "--no-renames", "-z", f"{base}{diff_range}{head}", "--",
        ])
    except subprocess.CalledProcessError:
        return None
    return [name.decode("utf-8", errors="surrogateescape") for name in output.split(b"\0") if name]


def main() -> None:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    paths = changed_paths(event, os.environ["GITHUB_EVENT_NAME"])
    desktop, capture = required_products(paths)
    native = desktop or capture
    demos = paths is None or any(name.startswith("docs/demos/") for name in paths)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"desktop_required={str(desktop).lower()}\n")
        output.write(f"capture_required={str(capture).lower()}\n")
        output.write(f"native_required={str(native).lower()}\n")
        output.write(f"demos_changed={str(demos).lower()}\n")
    print(f"Required checks: desktop={desktop}, capture={capture}; documentation always runs.")


if __name__ == "__main__":
    main()
