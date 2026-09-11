from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "scripts" / "repair_codex_history.py"
spec = importlib.util.spec_from_file_location("repair_codex_history", SCRIPT)
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)
FIRST = "11111111-1111-4111-8111-111111111111"
SECOND = "22222222-2222-4222-8222-222222222222"
OTHER = "33333333-3333-4333-8333-333333333333"


class HistoryRepairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.homes = [self.root / "default home", self.root / "other home"]
        for home in self.homes:
            home.mkdir()
        self.catalog = self.root / "catalog #1.sqlite"
        with sqlite3.connect(self.catalog) as database:
            database.executescript("""
                CREATE TABLE runtimes (id TEXT PRIMARY KEY, runtime_id TEXT);
                CREATE TABLE sessions (runtime_target_id TEXT, id TEXT);
                INSERT INTO runtimes VALUES ('codex-target', 'codex'), ('hermes-target', 'hermes');
            """)
            database.executemany(
                "INSERT INTO sessions VALUES (?, ?)",
                [
                    ("codex-target", FIRST),
                    ("codex-target", SECOND),
                    ("hermes-target", OTHER),
                ],
            )

    def rollout(self, home, session_id, text="history", metadata_id=None):
        path = (
            home
            / "sessions"
            / "2026/09/11"
            / f"rollout-2026-09-11T00-00-00-{session_id}.jsonl"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {"type": "session_meta", "payload": {"id": metadata_id or session_id}}
            )
            + "\n"
            + text,
            encoding="utf-8",
        )
        return path

    def plan(self):
        return repair.plan_repair(self.catalog, "codex-target", self.homes)

    def test_repair_shares_originals_in_both_directions_and_is_idempotent(self):
        first = self.rollout(self.homes[0], FIRST)
        second = self.rollout(self.homes[1], SECOND)
        catalog_before = self.catalog.read_bytes()
        report = self.plan()
        self.assertEqual(len(report["links"]), 2)
        self.assertTrue(
            all(not Path(link["link"]).exists() for link in report["links"])
        )
        repair.apply_repair(report)
        for link in report["links"]:
            self.assertTrue(Path(link["link"]).is_symlink())
            self.assertTrue(Path(link["link"]).samefile(link["source"]))
        first.write_text(first.read_text() + "\ncontinued")
        linked = next(
            Path(link["link"]) for link in report["links"] if link["sessionId"] == FIRST
        )
        self.assertTrue(linked.read_text().endswith("continued"))
        self.assertFalse(first.is_symlink())
        self.assertFalse(second.is_symlink())
        self.assertEqual(self.plan()["links"], [])
        self.assertEqual(self.catalog.read_bytes(), catalog_before)

    def test_unrelated_and_archived_sessions_are_not_linked(self):
        self.rollout(self.homes[0], FIRST)
        self.rollout(self.homes[0], OTHER)
        archived = self.rollout(self.homes[0], SECOND)
        archived.rename(self.homes[0] / archived.name)
        report = self.plan()
        self.assertEqual([link["sessionId"] for link in report["links"]], [FIRST])
        self.assertEqual(report["missingSessionIds"], [SECOND])

    def test_existing_different_histories_are_preserved(self):
        first = self.rollout(self.homes[0], FIRST, "original")
        other = self.rollout(self.homes[1], FIRST, "different")
        repair.apply_repair(self.plan())
        self.assertTrue(first.read_text().endswith("original"))
        self.assertTrue(other.read_text().endswith("different"))

    def test_conflicting_sources_cannot_choose_a_history_for_a_third_home(self):
        self.rollout(self.homes[0], FIRST, "original")
        self.rollout(self.homes[1], FIRST, "different")
        third = self.root / "third"
        third.mkdir()
        self.homes.append(third)
        with self.assertRaisesRegex(repair.HistoryRepairError, "Conflicting source"):
            self.plan()
        self.assertEqual(list(third.iterdir()), [])

    def test_mismatched_metadata_rejects_entire_plan(self):
        self.rollout(self.homes[0], FIRST)
        self.rollout(self.homes[0], SECOND, metadata_id=OTHER)
        with self.assertRaisesRegex(repair.HistoryRepairError, "metadata"):
            self.plan()
        self.assertEqual(list(self.homes[1].iterdir()), [])

    def test_dangling_link_is_not_replaced(self):
        source = self.rollout(self.homes[0], FIRST)
        target = self.homes[1] / source.relative_to(self.homes[0])
        target.parent.mkdir(parents=True)
        target.symlink_to(self.root / "missing")
        with self.assertRaises(OSError):
            self.plan()
        self.assertEqual(target.readlink(), self.root / "missing")

    def test_ambiguous_duplicate_rollouts_are_rejected(self):
        source = self.rollout(self.homes[0], FIRST)
        duplicate = source.parent / f"rollout-other-{FIRST}.jsonl"
        duplicate.write_bytes(source.read_bytes())
        with self.assertRaisesRegex(repair.HistoryRepairError, "Multiple rollouts"):
            self.plan()

    def test_source_outside_supplied_homes_is_rejected(self):
        source = self.rollout(self.homes[0], FIRST)
        outside = self.root / "outside.jsonl"
        source.rename(outside)
        source.symlink_to(outside)
        with self.assertRaisesRegex(repair.HistoryRepairError, "outside"):
            self.plan()

    def test_destination_directory_symlink_cannot_escape_home(self):
        self.rollout(self.homes[0], FIRST)
        outside = self.root / "outside"
        outside.mkdir()
        (self.homes[1] / "sessions").mkdir()
        (self.homes[1] / "sessions/2026").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(repair.HistoryRepairError, "escapes"):
            self.plan()
        self.assertEqual(list(outside.iterdir()), [])

    def test_destination_appearing_after_preview_is_not_replaced(self):
        self.rollout(self.homes[0], FIRST)
        report = self.plan()
        target = self.rollout(self.homes[1], FIRST, "new history")
        with self.assertRaisesRegex(repair.HistoryRepairError, "existing path"):
            repair.apply_repair(report)
        self.assertTrue(target.read_text().endswith("new history"))
        self.assertFalse(target.is_symlink())

    def test_other_runtime_and_missing_catalog_are_rejected(self):
        with self.assertRaisesRegex(repair.HistoryRepairError, "Codex runtime"):
            repair.plan_repair(self.catalog, "hermes-target", self.homes)
        missing = self.root / "missing.sqlite"
        with self.assertRaises(sqlite3.OperationalError):
            repair.plan_repair(missing, "codex-target", self.homes)
        self.assertFalse(missing.exists())

    def test_invalid_catalog_id_is_rejected(self):
        with sqlite3.connect(self.catalog) as database:
            database.execute(
                "INSERT INTO sessions VALUES ('codex-target', '../../outside')"
            )
        with self.assertRaisesRegex(repair.HistoryRepairError, "Invalid Codex session"):
            self.plan()

    def test_broken_session_directory_link_is_rejected(self):
        (self.homes[1] / "sessions").symlink_to(
            self.root / "missing", target_is_directory=True
        )
        with self.assertRaisesRegex(
            repair.HistoryRepairError, "Broken session-directory"
        ):
            self.plan()

    def test_partial_apply_keeps_a_record_of_created_links(self):
        self.rollout(self.homes[0], FIRST)
        self.rollout(self.homes[1], SECOND)
        report = self.plan()
        original = Path.symlink_to

        def fail_second(path, target):
            if report["createdLinks"]:
                raise PermissionError("fixture link permission failure")
            original(path, target)

        with mock.patch.object(Path, "symlink_to", fail_second):
            with self.assertRaises(PermissionError):
                repair.apply_repair(report)
        self.assertEqual(len(report["createdLinks"]), 1)
        self.assertTrue(Path(report["createdLinks"][0]).is_symlink())
        self.assertEqual(len(self.plan()["links"]), 1)

    def test_cli_previews_then_applies_and_reports_missing_history(self):
        self.rollout(self.homes[0], FIRST)
        command = [
            sys.executable,
            str(SCRIPT),
            "--catalog",
            str(self.catalog),
            "--runtime-target-id",
            "codex-target",
        ]
        for home in self.homes:
            command += ["--home", str(home)]
        preview = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(preview.returncode, 2, preview.stderr)
        self.assertEqual(json.loads(preview.stdout)["status"], "preview")
        self.assertEqual(list(self.homes[1].iterdir()), [])
        applied = subprocess.run(command + ["--apply"], capture_output=True, text=True)
        self.assertEqual(applied.returncode, 2, applied.stderr)
        report = json.loads(applied.stdout)
        self.assertEqual(report["status"], "applied")
        self.assertEqual(report["missingSessionIds"], [SECOND])
        self.assertEqual(len(report["createdLinks"]), 1)


if __name__ == "__main__":
    unittest.main()
