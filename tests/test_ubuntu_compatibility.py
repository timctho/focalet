"""Guard the Ubuntu package baseline, including real ELF version requirements."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import ubuntu_compatibility as compatibility


class UbuntuCompatibilityTests(unittest.TestCase):
    def test_builds_require_ubuntu_24_04_including_point_releases(self):
        with mock.patch.object(compatibility.platform, "freedesktop_os_release", return_value={
            "ID": "ubuntu", "VERSION_ID": "24.04", "PRETTY_NAME": "Ubuntu 24.04.5 LTS",
        }):
            compatibility.verify_build_host()
        for release in (
            {"ID": "ubuntu", "VERSION_ID": "22.04"},
            {"ID": "ubuntu", "VERSION_ID": "26.04"},
            {"ID": "debian", "VERSION_ID": "24.04"},
            {},
        ):
            with self.subTest(release=release), mock.patch.object(
                compatibility.platform, "freedesktop_os_release", return_value=release,
            ), self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "must be built on Ubuntu 24.04"):
                compatibility.verify_build_host()

    def test_unidentifiable_build_host_is_rejected(self):
        with mock.patch.object(compatibility.platform, "freedesktop_os_release", side_effect=OSError), \
                self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "Cannot identify"):
            compatibility.verify_build_host()

    def test_imports_are_separate_from_library_exports(self):
        output = """
Version definition section '.gnu.version_d' contains 1 entry:
  0x0020: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: GLIBC_2.99
Version needs section '.gnu.version_r' contains 1 entry:
  000000: Version: 1  File: libc.so.6  Cnt: 1
  0x0010:   Name: GLIBC_2.39  Flags: none  Version: 3
Version symbols section '.gnu.version' contains 4 entries:
  000: 0 (*local*) 2 (GLIBC_2.99) 3 (GLIBC_2.39)
"""
        self.assertEqual(compatibility.required_symbol_versions(output), {"GLIBC_2.39"})

    def test_missing_inspection_tool_fails_closed(self):
        with mock.patch.object(compatibility.shutil, "which", return_value=None), \
                self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "install binutils"):
            compatibility.verify_ubuntu_abi(Path("unused"))


@unittest.skipUnless(sys.platform == "linux" and shutil.which("cc") and shutil.which("readelf"),
                     "Linux C compiler and binutils required")
class NativeElfCompatibilityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="zommi-elf-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.package = self.root / "package"
        self.plugins = self.package / "lib/plugins"
        self.plugins.mkdir(parents=True)
        (self.package / "notes.txt").write_text("GLIBC_2.99 in an asset is not an ELF requirement.")
        self.provider = self.root / "provider.c"
        self.provider.write_text("int fixture(void) { return 42; }\n")
        self.consumer = self.root / "consumer.c"
        self.consumer.write_text("int fixture(void); int call(void) { return fixture(); }\n")

    def compile_fixture(self, version):
        version_script = self.root / "versions.map"
        version_script.write_text(f"{version} {{ global: fixture; }};\n")
        subprocess.run([
            "cc", "-shared", "-fPIC", "-nostdlib", str(self.provider),
            f"-Wl,--version-script={version_script}", "-Wl,-soname,libfixture.so",
            "-o", str(self.package / "libfixture.so"),
        ], check=True, capture_output=True)
        subprocess.run([
            "cc", "-shared", "-fPIC", "-nostdlib", str(self.consumer),
            f"-L{self.package}", "-lfixture", "-o", str(self.plugins / "consumer.so"),
        ], check=True, capture_output=True)

    def test_real_elf_at_the_baseline_and_older_versions_pass(self):
        for version in ("GLIBC_2.9", "GLIBC_2.39", "GLIBCXX_3.4.32", "CXXABI_1.3.14",
                        "GLIBC_ABI_DT_RELR", "CXXABI_TM_1", "CXXABI_FLOAT128"):
            with self.subTest(version=version):
                self.compile_fixture(version)
                result = compatibility.verify_ubuntu_abi(self.package)
                self.assertEqual(result["elfFiles"], 2)
                if version in compatibility.SPECIAL_VERSIONS:
                    self.assertIn(version, result["specialRequired"])
                else:
                    family, number = version.split("_", 1)
                    self.assertEqual(result["maxRequired"][family], number)

    def test_nested_plugin_requiring_newer_or_private_abi_is_rejected(self):
        for version in ("GLIBC_2.40", "GLIBCXX_3.4.33", "CXXABI_1.3.15",
                        "GLIBC_PRIVATE", "GLIBC_FUTURE_ABI"):
            with self.subTest(version=version):
                self.compile_fixture(version)
                with self.assertRaises(compatibility.UbuntuCompatibilityError) as raised:
                    compatibility.verify_ubuntu_abi(self.package)
                self.assertIn("lib/plugins/consumer.so", str(raised.exception))
                self.assertIn(version, str(raised.exception))

    def test_newer_export_does_not_raise_the_required_baseline(self):
        self.compile_fixture("GLIBC_2.99")
        (self.plugins / "consumer.so").unlink()
        result = compatibility.verify_ubuntu_abi(self.package)
        self.assertEqual(result["elfFiles"], 1)
        self.assertEqual(result["maxRequired"], {})

    def test_library_alias_is_not_counted_twice(self):
        self.compile_fixture("GLIBC_2.39")
        (self.package / "alias.so").symlink_to("libfixture.so")
        self.assertEqual(compatibility.verify_ubuntu_abi(self.package)["elfFiles"], 2)

    def test_empty_or_corrupt_package_is_rejected(self):
        with self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "no ELF binaries"):
            compatibility.verify_ubuntu_abi(self.package)
        (self.package / "broken.so").write_bytes(b"\x7fELFbroken")
        with self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "Cannot inspect ELF file broken.so"):
            compatibility.verify_ubuntu_abi(self.package)

    def test_external_library_alias_is_rejected(self):
        (self.package / "external.so").symlink_to(self.root / "outside.so")
        with self.assertRaisesRegex(compatibility.UbuntuCompatibilityError, "symlink escapes"):
            compatibility.verify_ubuntu_abi(self.package)


if __name__ == "__main__":
    unittest.main()
