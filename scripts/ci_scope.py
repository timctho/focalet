"""Select the documentation-only lane; unknown changes require native checks."""
from __future__ import annotations

import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


ROOT_DOCUMENTS = {"README.md", "CONTRIBUTING.md", "AGENTS.md", "SECURITY.md", "LICENSE", "THIRD_PARTY_NOTICES.md"}
DOCUMENT_SUFFIXES = {".md", ".png", ".webp", ".svg", ".gif", ".mp4", ".css"}


def requires_native(paths: list[str]) -> bool:
    if not paths:
        return True
    for name in paths:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            return True
        if name in ROOT_DOCUMENTS:
            continue
        if path.parts[0] == "docs" and path.suffix in DOCUMENT_SUFFIXES:
            continue
        return True
    return False


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
    native = paths is None or requires_native(paths)
    demos = paths is None or any(name.startswith("docs/demos/") for name in paths)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"native_required={str(native).lower()}\n")
        output.write(f"demos_changed={str(demos).lower()}\n")
    print("Native checks required." if native else "Documentation-only change; native checks are not required.")


if __name__ == "__main__":
    main()
