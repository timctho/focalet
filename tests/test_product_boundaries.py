"""The standalone product must build and ship without a desktop app dependency."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from verify_capture_package import verify


class ProductBoundariesTests(unittest.TestCase):
    def dependencies(self, project):
        found = set()
        def visit(path):
            path = path.resolve()
            if path in found:
                return
            found.add(path)
            for reference in ET.parse(path).iter("ProjectReference"):
                visit(path.parent / reference.attrib["Include"].replace("\\", "/"))
        visit(project)
        return found

    def test_apps_share_libraries_without_referencing_each_other(self):
        apps = [ROOT / "src/Focalet.CaptureTool/Focalet.CaptureTool.csproj",
                ROOT / "src/Focalet.Windows/Focalet.Windows.csproj"]
        graphs = [self.dependencies(app) for app in apps]
        self.assertIn((ROOT / "src/Focalet.Capture.Windows/Focalet.Capture.Windows.csproj").resolve(), graphs[0] & graphs[1])
        for app, graph in zip(apps, graphs):
            for dependency in graph - {app.resolve()}:
                output = ET.parse(dependency).findtext("PropertyGroup/OutputType", "Library")
                self.assertEqual(output, "Library", f"{app} depends on executable {dependency}")
        for resource in ("ApplicationIcon", "ApplicationManifest"):
            value = ET.parse(apps[0]).findtext(f"PropertyGroup/{resource}")
            if value:
                self.assertTrue((apps[0].parent / value).resolve().is_relative_to(apps[0].parent))

    def package(self, root, **extra):
        files = {
            "Focalet.Capture.exe": b"MZ synthetic fixture",
            "LICENSE": b"fixture", "THIRD_PARTY_NOTICES.md": b"fixture", "README.md": b"fixture",
            "capture-tool-manifest.json": json.dumps({
                "product": "Focalet Capture", "gitCommit": "a" * 40,
                "runtime": "win-x64", "entryPoint": "Focalet.Capture.exe",
            }).encode(), **extra,
        }
        for name, content in files.items():
            (root / name).write_bytes(content)
        (root / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256(content).hexdigest()}  {name}\n" for name, content in files.items()))

    def test_capture_inventory_and_revision_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root)
            verify(root, "a" * 40)
            with self.assertRaisesRegex(ValueError, "revision"):
                verify(root, "b" * 40)
            (root / "Focalet.Capture.exe").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "Checksum"):
                verify(root, "a" * 40)
            self.package(root)
            (root / "unexpected.dll").touch()
            with self.assertRaisesRegex(ValueError, "inventory"):
                verify(root, "a" * 40)

    def test_capture_rejects_a_bundled_desktop_even_with_valid_checksums(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.package(root, **{"focalet-core-host.exe": b"MZ fixture"})
            with self.assertRaisesRegex(ValueError, "Desktop component"):
                verify(root, "a" * 40)


if __name__ == "__main__":
    unittest.main()
