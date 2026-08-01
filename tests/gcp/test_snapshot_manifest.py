import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from snapshot_manifest import ManifestError, build, validate, validate_commit, write_new


class SnapshotManifestTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "snapshot"
        self.root.mkdir()
        (self.root / "part.parquet").write_bytes(b"fixture")

    def tearDown(self):
        self.tmp.cleanup()

    def test_build_and_verify(self):
        manifest = build(self.root)
        validate(manifest, self.root)

    def test_snapshot_id_crc_and_remote_duplicates_are_bound(self):
        manifest = build(self.root)
        tampered_id = copy.deepcopy(manifest)
        tampered_id["snapshot_id"] = "0" * 64
        with self.assertRaises(ManifestError):
            validate(tampered_id, self.root)
        tampered_crc = copy.deepcopy(manifest)
        tampered_crc["objects"][0]["crc32c"] = "AAAAAA=="
        with self.assertRaises(ManifestError):
            validate(tampered_crc, self.root)
        item = manifest["objects"][0]
        remote = [{**item}, {**item}]
        with self.assertRaises(ManifestError):
            validate(manifest, remote=remote)

    def test_commit_binds_manifest_id_count_and_bytes(self):
        manifest = build(self.root)
        manifest_bytes = json.dumps(manifest, sort_keys=True).encode()
        commit = {
            "schema": "gcp-snapshot-commit-v1",
            "snapshot_id": manifest["snapshot_id"],
            "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "object_count": 1,
            "total_bytes": 7,
        }
        validate_commit(commit, manifest, manifest_bytes)
        for field, value in (("snapshot_id", "0" * 64), ("object_count", 2), ("total_bytes", 8)):
            bad = copy.deepcopy(commit)
            bad[field] = value
            with self.assertRaises(ManifestError):
                validate_commit(bad, manifest, manifest_bytes)

    def test_missing_modified_duplicate_traversal_and_partial_rejected(self):
        manifest = build(self.root)
        missing = Path(self.tmp.name) / "missing"
        missing.mkdir()
        with self.assertRaises(ManifestError):
            validate(manifest, missing)
        (self.root / "part.parquet").write_bytes(b"modified")
        with self.assertRaises(ManifestError):
            validate(manifest, self.root)
        duplicate = copy.deepcopy(manifest)
        duplicate["objects"].append(copy.deepcopy(duplicate["objects"][0]))
        with self.assertRaises(ManifestError):
            validate(duplicate)
        traversal = copy.deepcopy(manifest)
        traversal["objects"][0]["name"] = "../escape"
        with self.assertRaises(ManifestError):
            validate(traversal)
        with self.assertRaises(ManifestError):
            validate(manifest, remote=[])

    def test_symlink_and_overwrite_rejected(self):
        (self.root / "link").symlink_to(self.root / "part.parquet")
        with self.assertRaises(ManifestError):
            build(self.root)
        output = Path(self.tmp.name) / "manifest.json"
        write_new(output, {"first": True})
        with self.assertRaises(FileExistsError):
            write_new(output, {"second": True})


if __name__ == "__main__":
    unittest.main()
