"""Plan and publish a manually dispatched, exact-revision release."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from publish_release import ASSETS, PROFILES, validate_tag

ROOT = Path(__file__).resolve().parents[1]
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "release"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Run the release workflow from main.")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or commit != os.environ["GITHUB_SHA"]:
        raise ValueError("The checkout must match the workflow's exact source revision.")
    tag, profile = os.environ["RELEASE_TAG"], os.environ["RELEASE_PLATFORMS"]
    prerelease, publish = os.environ["RELEASE_PRERELEASE"], os.environ["RELEASE_PUBLISH"]
    if prerelease not in {"true", "false"} or publish not in {"true", "false"}:
        raise ValueError("Invalid release switches.")
    version = re.search(r"^version: (\d+\.\d+\.\d+)",
                        (ROOT / "src/Zommi.Flutter/pubspec.yaml").read_text(), re.M).group(1)
    matrix = plan(profile, tag, version, stable=prerelease == "false")
    if args.command == "plan":
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write("matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
        print(json.dumps({"source": commit, "tag": tag, "publish": publish, **matrix}, indent=2))
        return
    command = [sys.executable, str(ROOT / "scripts/publish_release.py"),
               "--repository", os.environ["GITHUB_REPOSITORY"], "--tag", tag,
               "--expected-commit", commit, "--platforms", profile, "--output", "artifacts/release"]
    for metadata in sorted((ROOT / "artifacts/installers").rglob("*.release.json")):
        command += ["--metadata", str(metadata)]
    if prerelease == "false":
        command.append("--stable")
    if publish == "true":
        command.append("--publish")
    subprocess.run(command, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
