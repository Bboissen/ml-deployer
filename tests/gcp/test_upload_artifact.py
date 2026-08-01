import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from snapshot_manifest import crc32c
from upload_artifact import ArtifactError, safe_object_name, upload


class ArtifactUploadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "config.json"
        self.path.write_bytes(b"fixture")

    def tearDown(self):
        self.tmp.cleanup()

    def test_object_path_is_scoped_to_run(self):
        self.assertEqual(safe_object_name("artifacts/runs/run-1/config.json"), "artifacts/runs/run-1/config.json")
        for name in ("../escape", "/absolute", "runs/run-1/config.json", "artifacts/runs/file.json"):
            with self.assertRaises(ArtifactError):
                safe_object_name(name)

    @patch("upload_artifact.urllib.request.urlopen")
    @patch("upload_artifact.access_token", return_value="not-a-real-token")
    def test_native_upload_is_create_only_and_verified(self, _token, urlopen):
        payload = {"size": "7", "crc32c": crc32c(self.path), "generation": "123"}
        response = MagicMock()
        response.__enter__.return_value = io.BytesIO(json.dumps(payload).encode())
        urlopen.return_value = response
        observed = upload(self.path, "artifacts/runs/run-1/config.json")
        request = urlopen.call_args.args[0]
        self.assertIn("ifGenerationMatch=0", request.full_url)
        self.assertIn("name=artifacts%2Fruns%2Frun-1%2Fconfig.json", request.full_url)
        self.assertTrue(request.get_header("Authorization").startswith("Bearer "))
        self.assertEqual(observed["generation"], "123")

    def test_wrong_identity_is_rejected(self):
        with self.assertRaises(ArtifactError):
            upload(self.path, "artifacts/runs/run-1/config.json", "wrong@example.com")


if __name__ == "__main__":
    unittest.main()
