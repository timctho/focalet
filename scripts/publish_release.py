#!/usr/bin/env python3
"""Prepare or publish verified installers in the source repository's Releases."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ASSETS = {
    ("windows", "x64"): "Zommi-Setup-x64.exe",
    ("macos", "arm64"): "Zommi-macOS-arm64.dmg",
    ("macos", "x64"): "Zommi-macOS-x64.dmg",
    ("linux", "x64"): "Zommi-Ubuntu-amd64.deb",
}

PROFILES = {
    "windows": {("windows", "x64")},
    "ubuntu": {("linux", "x64")},
    "windows-ubuntu": {("windows", "x64"), ("linux", "x64")},
    "macos": {("macos", "arm64"), ("macos", "x64")},
    "all": set(ASSETS),
}


def validate_tag(tag: str, version: str, *, stable: bool = False) -> None:
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?", tag):
        raise ValueError("Expected a version tag such as v0.1.0-preview.8.")
    base = f"v{version}"
    if tag != base and not tag.startswith(base + "-"):
        raise ValueError("The release tag must match the application version.")
    if stable and tag != base:
        raise ValueError("A stable release needs the exact application version tag without a suffix.")


def collect_assets(metadata: list[Path], commit: str, *, windows_only: bool = False,
                   platforms: str | None = None, tag: str | None = None) -> tuple[list[Path], dict]:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("A full source commit is required.")
    paths, records, targets = [], [], set()
    version = None
    for path in metadata:
        value = json.loads(path.read_text(encoding="utf-8"))
        target = (value.get("platform"), value.get("architecture"))
        if target not in ASSETS or target in targets:
            raise ValueError("Unknown or duplicate installer target.")
        if value.get("product") != "Zommi" or value.get("gitCommit") != commit:
            raise ValueError("Installer source revision does not match this release.")
        if value.get("file") != ASSETS[target]:
            raise ValueError("Unexpected installer filename.")
        if target[0] == "linux" and tag is not None and value.get("releaseTag") != tag:
            raise ValueError("Ubuntu installer version does not match the release tag.")
        if version is not None and value.get("version") != version:
            raise ValueError("Installer versions differ.")
        version = value.get("version")
        asset = path.parent / ASSETS[target]
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        if digest != value.get("sha256"):
            raise ValueError(f"Installer checksum mismatch: {asset.name}")
        targets.add(target)
        paths.append(asset)
        records.append({key: value[key] for key in (
            "file", "platform", "architecture", "sha256", "applicationSigning", "installerSigning"
        )})
    if windows_only and targets != {("windows", "x64")}:
        raise ValueError("A Windows-only preview needs exactly the Windows x64 installer.")
    if platforms is not None:
        if platforms not in PROFILES or targets != PROFILES[platforms]:
            raise ValueError("Installers must exactly match the selected platforms.")
    elif not windows_only and not {("windows", "x64"), ("macos", "arm64")} <= targets:
        raise ValueError("A release needs Windows x64 and Mac Apple Silicon installers.")
    return paths, {"product": "Zommi", "version": version, "gitCommit": commit, "assets": records}


def gh(*arguments: str) -> str:
    return subprocess.check_output(["gh", *arguments], text=True).strip()


def verify_destination(repository: str, commit: str, tag: str) -> None:
    # Releases inherit repository visibility. Never change it during publication.
    source = json.loads(gh("api", f"repos/{repository}/commits/{commit}"))
    if source.get("sha") != commit:
        raise ValueError("The destination does not contain the exact installer source revision.")
    # Do not attach accepted binaries to an existing tag for different source.
    tags = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repository}/tags?per_page=100"))
    for page in tags:
        for existing in page:
            if existing["name"] == tag and existing["commit"]["sha"] != commit:
                raise ValueError("The existing release tag points to a different source revision.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="timctho/zommi", help="Source repository, owner/name (visibility is preserved)")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--metadata", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="Directory for reviewable release notes and manifest")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--windows-only", action="store_true", help="Publish a preview with only the accepted Windows x64 installer")
    selection.add_argument("--platforms", choices=PROFILES, help="Require this exact set of installers")
    parser.add_argument("--stable", action="store_true", help="Publish a stable version as the latest release")
    parser.add_argument("--publish", action="store_true", help="Upload and publish a preview release after validation")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        raise ValueError("Expected an owner/repository destination.")
    assets, manifest = collect_assets(args.metadata, args.expected_commit, windows_only=args.windows_only,
                                      platforms=args.platforms, tag=args.tag)
    validate_tag(args.tag, manifest["version"], stable=args.stable)
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / "zommi-release.json"
    checksums = args.output / "SHA256SUMS.txt"
    notes = args.output / "release-notes.md"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    checksums.write_text("".join(f"{item['sha256']}  {item['file']}\n" for item in manifest["assets"]), encoding="ascii")
    lines = [f"Zommi {args.tag}", "", "| Computer | Download |", "| --- | --- |"]
    for item in manifest["assets"]:
        label = ("Windows 10/11 (x64)" if item["platform"] == "windows" else
                 "Ubuntu 24.04 LTS (x64)" if item["platform"] == "linux" else
                 "Mac Apple Silicon" if item["architecture"] == "arm64" else "Mac Intel")
        lines.append(f"| {label} | [{item['file']}](https://github.com/{args.repository}/releases/download/{args.tag}/{item['file']}) |")
    selected = {item["platform"] for item in manifest["assets"]}
    instructions = []
    if "windows" in selected:
        instructions.append("Windows: run Setup.")
    if "macos" in selected:
        instructions.append("Mac: open the DMG and drag Zommi.app to Applications.")
    if "linux" in selected:
        instructions.append("Ubuntu: run `sudo apt install ./Zommi-Ubuntu-amd64.deb`, then open Zommi from the app menu.")
    lines += ["", " ".join(instructions),
              "Choose your installed agent runtime in the first-launch setup.", "",
              "See the exact signing status in zommi-release.json; Windows/macOS may require opening confirmation.",
              "See the repository README for installation instructions. SHA256SUMS.txt verifies the downloads.", "",
              f"Source revision: `{args.expected_commit}`. Build identity and signing status: `zommi-release.json`."]
    notes.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if not args.publish:
        print(f"Prepared release files in {args.output}; no GitHub changes made.")
        return 0
    verify_destination(args.repository, args.expected_commit, args.tag)
    upload_paths = [*assets, manifest_path, checksums]
    expected_hashes = {path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() for path in upload_paths}
    existing = subprocess.run(["gh", "release", "view", args.tag, "--repo", args.repository, "--json", "isDraft,assets"], text=True, capture_output=True)
    if existing.returncode == 0:
        draft = json.loads(existing.stdout)
        if not draft["isDraft"]:
            raise ValueError("Refusing to overwrite a published release; choose a new version tag.")
        if {item["name"] for item in draft["assets"]} - expected_hashes.keys():
            raise ValueError("The draft contains unexpected assets; review them before publishing.")
    else:
        gh("release", "create", args.tag, "--repo", args.repository, "--target", args.expected_commit,
           "--draft", f"--prerelease={'false' if args.stable else 'true'}", "--title", f"Zommi {args.tag}", "--notes-file", str(notes))
    gh("release", "upload", args.tag, "--repo", args.repository, *map(str, upload_paths), "--clobber")
    uploaded = json.loads(gh("release", "view", args.tag, "--repo", args.repository, "--json", "assets"))
    if {item["name"]: item.get("digest") for item in uploaded["assets"]} != expected_hashes:
        raise ValueError("Uploaded installer digests differ; the release remains a draft.")
    # Also bind a resumed draft to this revision before publishing it.
    verify_destination(args.repository, args.expected_commit, args.tag)
    gh("release", "edit", args.tag, "--repo", args.repository, "--target", args.expected_commit,
       "--notes-file", str(notes), "--draft=false", f"--prerelease={'false' if args.stable else 'true'}",
       f"--latest={'true' if args.stable else 'false'}")
    print(gh("release", "view", args.tag, "--repo", args.repository, "--json", "url", "--jq", ".url"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
