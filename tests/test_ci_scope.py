"""Documentation shortcuts must never bypass checks for executable changes."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ci_scope
from verify_ci_gate import check_state


class ScopeTests(unittest.TestCase):
    def test_documents_only(self):
        self.assertFalse(ci_scope.requires_native(["README.md", "docs/install.md", "docs/assets/social-card.png"]))

    def test_unknown_empty_and_executable_changes_require_native_checks(self):
        for paths in [[], ["README.md", "src/Zommi.Flutter/pubspec.yaml"], ["docs/hook.py"],
                      ["docs/demo.json"], [".github/workflows/checks.yml"], ["scripts/ci_scope.py"],
                      ["docs/../src/main.rs"], ["Cargo.lock"], ["tests/test_ci_scope.py"]]:
            with self.subTest(paths=paths):
                self.assertTrue(ci_scope.requires_native(paths))

    def test_product_local_changes_select_only_their_native_lane(self):
        for paths, expected in [
            (["README.md", "docs/capture-tool.md"], (False, False)),
            (["src/Zommi.CaptureTool/CapturePasteTool.cs", "docs/capture-tool.md"], (False, True)),
            (["scripts/package-capture-tool.ps1"], (False, True)),
            (["src/Zommi.Flutter/lib/main.dart"], (True, False)),
            (["crates/zommi-core/src/lib.rs"], (True, False)),
            (["src/Zommi.Capture.Core/CaptureModels.cs"], (True, True)),
            (["src/Zommi.Capture.Windows/ContentSelectionForm.cs"], (True, True)),
            (["src/Zommi.CaptureTool/A.cs", "src/Zommi.Flutter/lib/main.dart"], (True, True)),
            (["src/Zommi.CaptureTool/../../something"], (True, True)),
            ([".github/workflows/checks.yml"], (True, True)),
            (None, (True, True)), ([], (True, True)), ([""], (True, True)),
        ]:
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.required_products(paths), expected)

    def test_move_from_source_to_docs_still_requires_native_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            git("init", "-q")
            git("config", "user.email", "fixture@example.test")
            git("config", "user.name", "Fixture")
            (root / "program.py").write_text("print('source')\n")
            git("add", ".")
            git("commit", "-qm", "source")
            base = git("rev-parse", "HEAD")
            (root / "docs").mkdir()
            (root / "program.py").rename(root / "docs/example.md")
            git("add", "-A")
            git("commit", "-qm", "move")
            event = {"before": base, "after": git("rev-parse", "HEAD")}
            script = ("import ci_scope,json; p=ci_scope.changed_paths(json.loads(" + repr(json.dumps(event))
                      + "),'push'); assert 'program.py' in p; assert ci_scope.requires_native(p)")
            subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0," + repr(str(Path(ci_scope.__file__).parent)) + ");" + script], cwd=root, check=True)

    def test_unknown_event_and_initial_push_default_to_native(self):
        self.assertIsNone(ci_scope.changed_paths({}, "workflow_dispatch"))
        self.assertIsNone(ci_scope.changed_paths({"before": "0" * 40, "after": "a" * 40}, "push"))


class PublicationGateTests(unittest.TestCase):
    def run_record(self, **changes):
        return dict({"id": 1, "head_sha": "a" * 40, "head_branch": "main", "event": "push",
                     "status": "completed", "conclusion": "success"}, **changes)

    def test_only_exact_main_push_checks_count(self):
        for changes in [{"head_sha": "b" * 40}, {"head_branch": "feature"}, {"event": "workflow_dispatch"}, {"event": "pull_request"}]:
            self.assertEqual(check_state([self.run_record(**changes)], "a" * 40), "pending")
        self.assertEqual(check_state([self.run_record()], "a" * 40), "success")

    def test_later_run_supersedes_old_success(self):
        old = self.run_record()
        self.assertEqual(check_state([old, self.run_record(id=2, status="in_progress")], "a" * 40), "pending")
        for conclusion in ["failure", "cancelled", "skipped", "timed_out", None]:
            self.assertEqual(check_state([old, self.run_record(id=2, conclusion=conclusion)], "a" * 40), "failure")


if __name__ == "__main__":
    unittest.main()
