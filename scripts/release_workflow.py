"""Release main's version changes, or manually build an exact revision."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from publish_release import ASSETS, PROFILES, validate_tag
from release_version import parse_version, read_version

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = "src/Focalet.Flutter/pubspec.yaml"
AUTOMATIC_PLATFORMS = "all"
RUNNERS = {
    ("windows", "x64"): "windows-2025",
    ("linux", "x64"): "ubuntu-24.04",
    ("macos", "arm64"): "macos-15",
    ("macos", "x64"): "macos-15-intel",
}


def plan(profile: str, tag: str, version: str, *, stable: bool = False) -> dict:
    validate_tag(tag, version, stable=stable)
    if profile not in PROFILES:
        raise ValueError("Unknown release platforms.")
    return {"include": [
        {"platform": platform, "architecture": architecture, "os": RUNNERS[(platform, architecture)],
         "asset": ASSETS[(platform, architecture)]}
        for platform, architecture in sorted(PROFILES[profile])
    ]}


def release_request(commit: str, tag: str) -> tuple[bool, str, str]:
    """Compare the whole push, not just its last commit or today's main tip."""
    event_name = os.environ.get("GITHUB_EVENT_NAME")
    if event_name == "workflow_dispatch":
        return True, os.environ["RELEASE_PLATFORMS"], os.environ["RELEASE_PUBLISH"]
    if event_name != "push":
        raise ValueError("Only main pushes and manual dispatches may release.")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    before = event.get("before", "")
    if event.get("after") != commit:
        raise ValueError("The push must match the workflow's exact source revision.")
    if not isinstance(before, str) or not re.fullmatch(r"[0-9a-f]{40}", before) or before == "0" * 40:
        raise ValueError("A version-changing push needs an existing main revision to compare.")
    # The first renamed release may compare against a pre-rename main revision.
    # Do not suppress malformed versions or unknown commits; only probe the
    # former path when the current path did not exist in that exact revision.
    previous_file = VERSION_FILE
    exists = subprocess.run(["git", "cat-file", "-e", f"{before}:{previous_file}"],
                            cwd=ROOT, capture_output=True).returncode == 0
    if not exists:
        previous_file = "src/Zommi.Flutter/pubspec.yaml"
    previous = parse_version(subprocess.check_output(
        ["git", "show", f"{before}:{previous_file}"], cwd=ROOT, text=True,
    ))
    return previous["tag"] != tag, AUTOMATIC_PLATFORMS, "true"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "release"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Run the release workflow from main.")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or commit != os.environ["GITHUB_SHA"]:
        raise ValueError("The checkout must match the workflow's exact source revision.")
    identity = read_version(ROOT / VERSION_FILE)
    tag, prerelease = identity["tag"], identity["prerelease"]
    if args.command == "plan":
        build, profile, publish = release_request(commit, tag)
    else:
        profile, publish = os.environ["RELEASE_PLATFORMS"], os.environ["RELEASE_PUBLISH"]
    if publish not in {"true", "false"}:
        raise ValueError("Invalid publish switch.")
    matrix = plan(profile, tag, identity["version"], stable=not prerelease)
    if args.command == "plan":
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
            output.write(f"tag={tag}\nprerelease={str(prerelease).lower()}\n")
            output.write(f"build={str(build).lower()}\nplatforms={profile}\npublish={publish}\n")
        if not build:
            print(f"Release version is unchanged ({tag}); skipping installers and publication.")
        print(json.dumps({"source": commit, "tag": tag, "prerelease": prerelease,
                          "build": build, "platforms": profile, "publish": publish, **matrix}, indent=2))
        return
    command = [sys.executable, str(ROOT / "scripts/publish_release.py"),
               "--repository", os.environ["GITHUB_REPOSITORY"], "--tag", tag,
               "--expected-commit", commit, "--platforms", profile, "--output", "artifacts/release"]
    for metadata in sorted((ROOT / "artifacts/installers").rglob("*.release.json")):
        command += ["--metadata", str(metadata)]
    if not prerelease:
        command.append("--stable")
    if publish == "true":
        command.append("--publish")
    subprocess.run(command, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
