#!/usr/bin/env python3
"""Restore missing Codex rollout lookups for one Zommi catalog runtime."""

from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid


class HistoryRepairError(RuntimeError):
    pass


def catalog_session_ids(catalog: Path, runtime_target_id: str) -> set[str]:
    # mode=ro also prevents a misspelled catalog path from creating a database.
    with closing(sqlite3.connect(catalog.resolve().as_uri() + "?mode=ro")) as database:
        runtime = database.execute(
            "SELECT runtime_id FROM runtimes WHERE id = ?", (runtime_target_id,)
        ).fetchone()
        if runtime != ("codex",):
            raise HistoryRepairError("Choose a Codex runtime target from the catalog.")
        ids = {
            row[0]
            for row in database.execute(
                "SELECT id FROM sessions WHERE runtime_target_id = ?",
                (runtime_target_id,),
            )
        }
    for session_id in ids:
        try:
            valid = str(uuid.UUID(session_id)) == session_id
        except (ValueError, TypeError, AttributeError):
            valid = False
        if not valid:
            raise HistoryRepairError(f"Invalid Codex session ID: {session_id!r}")
    return ids


def validate_rollout(path: Path, session_id: str, roots: list[Path]) -> Path:
    source = path.resolve(strict=True)
    if not source.is_file() or not any(source.is_relative_to(root) for root in roots):
        raise HistoryRepairError(
            f"Rollout is outside the supplied session directories: {path}"
        )
    with source.open(encoding="utf-8") as stream:
        # Only the metadata record is needed; transcripts never enter the report.
        line = stream.readline(1024 * 1024)
    try:
        metadata = json.loads(line)
        matches = (
            isinstance(metadata, dict)
            and metadata.get("type") == "session_meta"
            and isinstance(metadata.get("payload"), dict)
            and metadata["payload"].get("id") == session_id
        )
    except (ValueError, UnicodeError):
        matches = False
    if not matches:
        raise HistoryRepairError(
            f"Rollout metadata does not match its session ID: {path}"
        )
    return source


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def check_destination(destination: Path, root: Path) -> None:
    if not destination.parent.resolve().is_relative_to(root):
        raise HistoryRepairError(
            f"Destination escapes its session directory: {destination}"
        )
    if destination.exists() or destination.is_symlink():
        raise HistoryRepairError(f"Refusing to replace an existing path: {destination}")


def plan_repair(catalog: Path, runtime_target_id: str, homes: list[Path]) -> dict:
    roots = []
    for home in homes:
        if not home.is_dir():
            raise HistoryRepairError(f"Codex home does not exist: {home}")
        session_directory = home.resolve() / "sessions"
        if session_directory.is_symlink() and not session_directory.exists():
            raise HistoryRepairError(
                f"Broken session-directory link: {session_directory}"
            )
        root = session_directory.resolve()
        if root.exists() and not root.is_dir():
            raise HistoryRepairError(f"Session directory is not a directory: {root}")
        if root not in roots:
            roots.append(root)
    if len(roots) < 2:
        raise HistoryRepairError(
            "Supply at least two distinct Codex session directories."
        )

    ids = catalog_session_ids(catalog, runtime_target_id)
    found: dict[str, dict[Path, Path]] = {session_id: {} for session_id in ids}
    for root in roots:
        # Do not follow directory symlinks or scan archived sessions.
        def walk_error(error: OSError) -> None:
            raise error

        if not root.exists():
            continue
        for directory, _, files in os.walk(root, followlinks=False, onerror=walk_error):
            for name in files:
                if not name.startswith("rollout-") or not name.endswith(".jsonl"):
                    continue
                session_id = name[-42:-6]
                if session_id not in ids:
                    continue
                path = Path(directory) / name
                validate_rollout(path, session_id, roots)
                if root in found[session_id]:
                    raise HistoryRepairError(
                        f"Multiple rollouts for session {session_id} in {root}"
                    )
                found[session_id][root] = path

    links = []
    missing = []
    for session_id, locations in sorted(found.items()):
        if not locations:
            missing.append(session_id)
            continue
        if len(locations) == len(roots):
            continue  # Existing histories are never reconciled or replaced.
        source_root, source_path = next(iter(locations.items()))
        source = source_path.resolve(strict=True)
        originals = {path.resolve(strict=True) for path in locations.values()}
        if len(originals) > 1 and len({digest(path) for path in originals}) > 1:
            raise HistoryRepairError(
                f"Conflicting source histories for session {session_id}"
            )
        for root in roots:
            if root in locations:
                continue
            destination = root / source_path.relative_to(source_root)
            check_destination(destination, root)
            links.append(
                {
                    "sessionId": session_id,
                    "source": str(source),
                    "link": str(destination),
                }
            )
    return {
        "runtimeTargetId": runtime_target_id,
        "sessionDirectories": [str(root) for root in roots],
        "catalogSessions": len(ids),
        "missingSessionIds": missing,
        "links": links,
        "createdLinks": [],
        "status": "preview",
    }


def apply_repair(report: dict) -> None:
    roots = [Path(root) for root in report["sessionDirectories"]]
    # Validate the entire plan before writing. symlink_to uses exclusive creation
    # as well, so a destination created concurrently is never overwritten.
    for link in report["links"]:
        validate_rollout(Path(link["source"]), link["sessionId"], roots)
        destination = Path(link["link"])
        root = next(root for root in roots if destination.is_relative_to(root))
        check_destination(destination, root)
    for link in report["links"]:
        destination = Path(link["link"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(link["source"])
        report["createdLinks"].append(str(destination))
    report["status"] = "applied"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--catalog", type=Path, required=True, help="Zommi session-catalog.sqlite"
    )
    parser.add_argument(
        "--runtime-target-id",
        required=True,
        help="Exact Codex runtime target in that catalog",
    )
    parser.add_argument(
        "--home",
        type=Path,
        action="append",
        required=True,
        help="Codex home to reconcile; repeat for each home",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Create the previewed links; defaults to a read-only preview",
    )
    args = parser.parse_args()
    report = {"status": "failed", "createdLinks": []}
    try:
        report = plan_repair(args.catalog, args.runtime_target_id, args.home)
        if args.apply:
            apply_repair(report)
    except (HistoryRepairError, OSError, sqlite3.Error, UnicodeError) as error:
        report.update(status="failed", error=str(error))
        print(json.dumps(report, indent=2))
        return 1
    print(json.dumps(report, indent=2))
    return 2 if report["missingSessionIds"] else 0


if __name__ == "__main__":
    sys.exit(main())
