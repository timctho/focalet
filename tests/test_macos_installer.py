from __future__ import annotations

from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
import build_installer


class MacInstallerTests(unittest.TestCase):
    def test_sparse_payload_is_sized_from_full_length_with_filesystem_headroom(self):
        with tempfile.TemporaryDirectory() as temporary:
            layout = Path(temporary)
            binary = layout / "native-helper"
            with binary.open("wb") as stream:
                stream.truncate(64 * 1024 * 1024 + 1)
            size = build_installer.dmg_size_megabytes(layout) * 1024 * 1024
            self.assertGreaterEqual(size, binary.stat().st_size + 32 * 1024 * 1024)

    @unittest.skipIf(sys.platform == "win32", "Mac layout uses Unix symlinks")
    def test_applications_link_does_not_add_the_hosts_applications_to_the_volume(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = root / "layout"
            layout.mkdir()
            outside = root / "host-applications"
            outside.mkdir()
            with (outside / "unrelated-app").open("wb") as stream:
                stream.truncate(512 * 1024 * 1024)
            before = build_installer.dmg_size_megabytes(layout)
            (layout / "Applications").symlink_to(outside, target_is_directory=True)
            self.assertLessEqual(build_installer.dmg_size_megabytes(layout), before + 1)

    @unittest.skipIf(sys.platform == "win32", "Mac layout uses Unix symlinks")
    def test_both_products_create_sized_images_and_verify_the_mounted_payload(self):
        for capture in (False, True):
            with self.subTest(capture=capture), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                package, output = root / "package", root / "output"
                output.mkdir()
                name = "Focalet Capture" if capture else "Focalet"
                app = package / f"{name}.app"
                app.mkdir(parents=True)
                (app / "binary").write_bytes(b"accepted signed payload")
                calls = []
                source = None

                def run(arguments, *, check):
                    nonlocal source
                    self.assertTrue(check)
                    calls.append(arguments)
                    if arguments[0] == "ditto":
                        shutil.copytree(arguments[1], arguments[2], symlinks=True)
                    elif arguments[:2] == ["hdiutil", "create"]:
                        source = Path(arguments[arguments.index("-srcfolder") + 1])
                        self.assertEqual(arguments[arguments.index("-fs") + 1], "HFS+")
                        capacity = arguments[arguments.index("-size") + 1]
                        self.assertTrue(capacity.endswith("m"))
                        self.assertGreaterEqual(int(capacity[:-1]), 32)
                        Path(arguments[-1]).write_bytes(b"DMG fixture")
                    elif arguments[:2] == ["hdiutil", "attach"]:
                        mounted = Path(arguments[arguments.index("-mountpoint") + 1])
                        shutil.copytree(source, mounted, symlinks=True, dirs_exist_ok=True)

                with patch.object(build_installer.platform, "system", return_value="Darwin"), \
                        patch.object(build_installer.subprocess, "run", side_effect=run):
                    asset = build_installer.macos_installer(package, output, {"architecture": "arm64"}, capture=capture)
                self.assertTrue(asset.is_file())
                self.assertTrue(any(call[:2] == ["hdiutil", "verify"] for call in calls))
                self.assertTrue(any(call[:2] == ["codesign", "--verify"] for call in calls))
                self.assertEqual(calls[-1][:2], ["hdiutil", "detach"])


if __name__ == "__main__":
    unittest.main()
