"""Public demo assets must retain the privacy-reviewed bytes and metadata."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "demos", Path(__file__).resolve().parents[1] / "scripts/verify_demo_assets.py"
)
demos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demos)


class DemoAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.content = b"reviewed fixture"
        (self.root / "clip.mp4").write_bytes(self.content)
        (self.root / "README.md").write_text("Synthetic demonstration")
        self.manifest = {
            "schemaVersion": 1,
            "recordings": [
                {
                    "buildCommit": "a" * 40,
                    "syntheticSource": True,
                    "audio": False,
                    "review": {
                        "ocrStatus": "no-matches",
                        "rawFramesScanned": 12,
                        "visualReview": True,
                    },
                    "assets": [
                        {
                            "file": "clip.mp4",
                            "bytes": len(self.content),
                            "sha256": hashlib.sha256(self.content).hexdigest(),
                        }
                    ],
                }
            ],
        }
        self.write_manifest()
        self.video = {"streams": [{"codec_type": "video"}]}

    def write_manifest(self):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))

    def verify(self, metadata=None):
        return demos.verify(self.root, probe=lambda _: metadata or self.video)

    def test_exported_frame_review_has_an_explicit_distinct_scope(self):
        review = self.manifest["recordings"][0]["review"]
        review["exportedFramesScanned"] = review.pop("rawFramesScanned")
        self.write_manifest()
        self.assertEqual(self.verify(), 1)
        review["rawFramesScanned"] = 12
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "privacy-review metadata"):
            self.verify()
        del review["rawFramesScanned"]
        review["exportedFramesScanned"] = True
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "review is incomplete"):
            self.verify()

    def test_reviewed_media_passes_but_changed_bytes_fail(self):
        self.assertEqual(self.verify(), 1)
        (self.root / "clip.mp4").write_bytes(b"changed after review")
        with self.assertRaisesRegex(ValueError, "changed"):
            self.verify()

    def test_accidental_profile_or_log_cannot_be_published(self):
        (self.root / "profile").mkdir()
        (self.root / "profile/settings.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "Unreviewed files"):
            self.verify()

    def test_real_product_pages_must_be_identified_without_relaxing_review(self):
        recording = self.manifest["recordings"][0]
        recording["syntheticSource"] = False
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "source classification"):
            self.verify()
        recording["sourceKind"] = "public-product-pages"
        self.write_manifest()
        self.assertEqual(self.verify(), 1)
        recording["review"]["visualReview"] = False
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "review is incomplete"):
            self.verify()
        recording["review"]["visualReview"] = True
        recording["syntheticSource"] = True
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "source classification"):
            self.verify()
        recording["sourceKind"] = "private-account"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "source classification"):
            self.verify()

    def test_raw_recording_metadata_cannot_be_added_to_the_public_manifest(self):
        self.manifest["profileDirectory"] = "/home/private/profile"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "manifest metadata"):
            self.verify()

    def test_audio_and_personal_metadata_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "tracks"):
            self.verify({"streams": [{"codec_type": "video"}, {"codec_type": "audio"}]})
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.verify(
                {
                    "streams": [{"codec_type": "video"}],
                    "format": {"tags": {"artist": "private"}},
                }
            )

    def test_review_is_required_and_paths_cannot_escape_the_demo_directory(self):
        recording = self.manifest["recordings"][0]
        recording["review"]["ocrStatus"] = "needs-review"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.verify()
        recording["review"]["ocrStatus"] = "no-matches"
        recording["assets"][0]["file"] = "../clip.mp4"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "basenames"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
