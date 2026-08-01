import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from snapshot_manifest import build
from upload_snapshot import PUBLISHER, file_metadata, upload, verify_remote


class UploadSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "part.parquet"
        self.path.write_bytes(b"fixture")
        self.expected = file_metadata(self.path)

    def tearDown(self):
        self.tmp.cleanup()

    @patch("upload_snapshot.verify_remote")
    @patch("upload_snapshot.run")
    def test_upload_is_create_only_and_sha_tagged(self, run, verify):
        uri = "gs://bucket/object"
        upload(self.path, uri, self.expected, PUBLISHER)
        command = run.call_args.args[0]
        self.assertIn("--if-generation-match=0", command)
        self.assertIn(f"--custom-metadata=sha256={self.expected['sha256']}", command)
        self.assertNotIn("--no-clobber", command)
        verify.assert_called_once_with(uri, self.expected, PUBLISHER)

    @patch("upload_snapshot.describe")
    def test_remote_size_crc_and_sha_are_verified(self, describe):
        describe.return_value = {
            "size": str(self.expected["size"]),
            "crc32c": self.expected["crc32c"],
            "metadata": {"sha256": self.expected["sha256"]},
        }
        verify_remote("gs://bucket/object", self.expected, PUBLISHER)
        describe.return_value["metadata"]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            verify_remote("gs://bucket/object", self.expected, PUBLISHER)

    @patch("upload_snapshot.describe")
    def test_gcloud_snake_case_metadata_is_verified(self, describe):
        describe.return_value = {
            "size": self.expected["size"],
            "crc32c_hash": self.expected["crc32c"],
            "custom_fields": {"sha256": self.expected["sha256"]},
        }
        verify_remote("gs://bucket/object", self.expected, PUBLISHER)

    def test_manifest_contains_crc32c(self):
        manifest = build(Path(self.tmp.name))
        json.dumps(manifest)
        self.assertTrue(manifest["objects"][0]["crc32c"])


if __name__ == "__main__":
    unittest.main()
