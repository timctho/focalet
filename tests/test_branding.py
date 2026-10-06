"""Keep legacy spelling confined to upgrade readers and historical documentation."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from migrate_legacy_settings import migrate, settings_paths


class BrandingTests(unittest.TestCase):
    def test_no_legacy_paths_or_active_product_names(self):
        compatibility = {
            "docs/migration.md", "scripts/migrate_legacy_settings.py",
            "scripts/release_workflow.py", "tests/test_release_workflow.py",
            "tests/test_branding.py", "src/Focalet.Flutter/lib/state/history_mapper.dart",
            "crates/focalet-core/src/codex_adapter.rs",
        }
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        for name in filter(None, paths):
            self.assertNotIn("zommi", name.lower(), name)
            if name in compatibility:
                continue
            data = (ROOT / name).read_bytes()
            if b"\0" in data:
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            self.assertNotIn("zommi", text.lower(), name)

    def test_settings_import_is_opt_in_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = settings_paths("linux", {"HOME": str(root)})
            self.assertEqual(paths[0][0], root / ".config/zommi/settings.json")
            self.assertEqual(paths[1][0], root / ".config/zommi/runtime-overrides.json")
            for source, _ in paths:
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text('[]' if source.name == "runtime-overrides.json" else '{"themeColor":"ocean"}')
            migrate(paths)
            self.assertFalse(paths[0][1].exists())
            migrate(paths, apply=True)
            for source, target in paths:
                self.assertEqual(source.read_bytes(), target.read_bytes())
            paths[0][1].write_text('{"themeColor":"mint"}')
            migrate(paths, apply=True)
            self.assertEqual(paths[0][1].read_text(), '{"themeColor":"mint"}')
            self.assertEqual(paths[0][0].read_text(), '{"themeColor":"ocean"}')
            self.assertEqual(set(p.name for p in paths[0][1].parent.iterdir()),
                             {"settings.json", "runtime-overrides.json"})

    def test_each_platform_uses_its_actual_configuration_roots(self):
        windows = settings_paths("win32", {"APPDATA": "/roaming", "LOCALAPPDATA": "/local"})
        self.assertEqual(windows, [(Path("/roaming/Zommi/settings.json"), Path("/roaming/Focalet/settings.json")),
                                   (Path("/local/Zommi/runtime-overrides.json"), Path("/local/Focalet/runtime-overrides.json"))])
        mac = settings_paths("darwin", {"HOME": "/fixture"})
        self.assertEqual(mac[1][1], Path("/fixture/Library/Application Support/Focalet/runtime-overrides.json"))


if __name__ == "__main__":
    unittest.main()
