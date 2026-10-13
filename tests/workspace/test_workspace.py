"""Offline behavior tests; all storage transfers here are simulated local copies."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from jsonschema.exceptions import ValidationError

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "shared/workspace/fixtures"
EXAMPLE = ROOT / "shared/workspace/example"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


validation = module("validation", ROOT / "scripts/workspace/validate.py")
example = module("example", EXAMPLE / "example.py")
probe = module("probe", ROOT / "scripts/workspace/probe-toolbox.py")


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        runtime = ROOT / "evidence/.test-runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=runtime)
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)

    def records(self, provider="aws"):
        return [json.loads((FIXTURES / f"{provider}-{kind}.json").read_text())
                for kind in ("request", "handoff", "readiness")]

    def validate(self, request, handoff=None, readiness=None, ready=True):
        for record in [v for v in (request, handoff, readiness) if v is not None]:
            validation.VALIDATOR.validate(record)
        validation.request_semantics(request)
        if handoff:
            validation.handoff_semantics(request, handoff)
        if readiness:
            validation.readiness_semantics(request, handoff, readiness, ready)

    def rejected(self, records):
        with self.assertRaises((ValueError, ValidationError)):
            self.validate(*records)

    def test_all_provider_records_and_cli(self):
        import sys
        for provider in ("aws",):
            with self.subTest(provider=provider):
                self.validate(*self.records(provider))
                result = subprocess.run([sys.executable, str(ROOT / "scripts/workspace/validate.py"),
                                         str(FIXTURES / f"{provider}-request.json"), "--handoff",
                                         str(FIXTURES / f"{provider}-handoff.json"), "--readiness",
                                         str(FIXTURES / f"{provider}-readiness.json"), "--require-ready"],
                                        check=True, capture_output=True)
                self.assertEqual(result.stdout, validation.canonical(self.records(provider)[2]))

    def test_closed_types_versions_and_id_boundaries(self):
        for field, value in (("schema_version", "1.0.0"), ("maximum_runtime_minutes", True),
                             ("maximum_runtime_minutes", 14), ("maximum_runtime_minutes", 721),
                             ("maximum_runtime_minutes", 60.5), ("provider", "gcp"),
                             ("operators", []), ("secret", "do-not-print-this"),
                             ("workspace_id", "a" * 49)):
            records = self.records()[:1]
            records[0][field] = value
            with self.subTest(field=field, value=value):
                self.rejected(records)
        request = self.records()[0]
        request["workspace_id"] = "a" * 48
        self.validate(request)
        for field in ("image", "run_spec", "model", "publisher", "access_key"):
            request = self.records()[0]
            request[field] = "unrequested"
            self.rejected([request])

    def test_native_storage_and_state_isolation(self):
        for provider in ("aws",):
            request = self.records(provider)[0]
            for value in (request["storage"]["data_uri"] + "?token=forbidden",
                          request["storage"]["data_uri"] + "../",
                          request["storage"]["data_uri"] + "%2e%2e/",
                          request["storage"]["data_uri"].rstrip("/"),
                          "gs://wrong-provider/data/"):
                changed = copy.deepcopy(request)
                changed["storage"]["data_uri"] = value
                self.rejected([changed])
            changed = copy.deepcopy(request)
            changed["storage"]["state_uri"] = request["storage"]["data_uri"] + "state.tfstate"
            self.rejected([changed])
            changed = copy.deepcopy(request)
            changed["storage"]["output_uri"] = request["storage"]["data_uri"] + "outputs/"
            self.rejected([changed])

    def test_handoff_rejects_rehashed_semantic_tampering(self):
        for key, value in (("provider", "gcp"), ("account_scope", "999999999999"),
                           ("workspace_id", "other-workspace"), ("user", "root"),
                           ("project_directory", "/home/workspace/../root")):
            records = self.records()
            records[1][key] = value
            records[2]["handoff_sha256"] = validation.digest(records[1])
            self.rejected(records)
        for field, value in (("guard_active_at", "2026-10-07T12:00:01Z"),
                             ("expires_at", "2026-10-07T13:00:01Z"),
                             ("expires_at", "2026-10-07T12:00:00Z"),
                             ("expiry_action", "deallocate")):
            records = self.records()
            records[1]["lifetime"][field] = value
            records[2]["handoff_sha256"] = validation.digest(records[1])
            self.rejected(records)
        records = self.records()
        records[1]["identity"]["selector"] = "arn:aws:iam::999999999999:role/other"
        self.rejected(records)
        records = self.records()
        records[1]["storage"]["output_uri"] += "other/"
        self.rejected(records)
        records = self.records()
        records[1]["terminal"]["argv"][0] = "bash"
        self.rejected(records)

    def test_readiness_is_bound_and_incomplete_checks_stay_closed(self):
        for status in ("fail", "unverified"):
            records = self.records()
            records[2]["checks"]["deadline"]["status"] = status
            self.validate(*records, ready=False)
            self.rejected(records)
        for field, value in (("request_sha256", "a" * 64), ("handoff_sha256", "b" * 64),
                             ("workspace_id", "other-workspace"),
                             ("observed_at", "2026-10-07T13:00:00Z"),
                             ("observed_at", "2026-10-07T11:59:59Z")):
            records = self.records()
            records[2][field] = value
            self.rejected(records)
        for field, value in (("cpus", 1), ("memory_mb", 2048), ("disk_gb", 10)):
            records = self.records()
            records[2]["resources"][field] = value
            self.rejected(records)
        records = self.records()
        records[2]["versions"]["python"] = "3.14.0"
        self.rejected(records)
        for path in ("evidence/gcp/workspace-example/check.json", "evidence/aws/workspace-example/../check.json"):
            records = self.records()
            records[2]["checks"]["identity"]["evidence"] = path
            self.rejected(records)

    def test_duplicate_fields_and_credential_values_are_not_echoed(self):
        import sys
        request = self.path / "request.json"
        request.write_text('{"schema_version":"2.0.0","schema_version":"1.0.0"}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            validation.load(request, "request")
        value = self.records()[0]
        value["secret"] = "do-not-print-this"
        request.write_text(json.dumps(value))
        result = subprocess.run([sys.executable, str(ROOT / "scripts/workspace/validate.py"), str(request)],
                                capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b"do-not-print-this", result.stdout + result.stderr)
        value.pop("secret")
        value["storage"]["data_uri"] = "s3://example:do-not-print-this/data/"
        request.write_text(json.dumps(value))
        result = subprocess.run([sys.executable, str(ROOT / "scripts/workspace/validate.py"), str(request)],
                                capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b"do-not-print-this", result.stdout + result.stderr)

    def test_example_repeats_and_reuses_simulated_bucket(self):
        fixture = self.path / "fixture.csv"
        shutil.copyfile(EXAMPLE / "fixture.csv", fixture)
        for workspace in ("first", "second"):
            output = self.path / f"{workspace}.json"
            example.calculate(fixture, output)
            # Simulated put/get; provider-only adapters must separately prove native auth/transfer.
            bucket_object = self.path / "bucket-object.json"
            shutil.copyfile(output, bucket_object)
            retrieved = self.path / f"{workspace}-retrieved.json"
            shutil.copyfile(bucket_object, retrieved)
            example.verify(output, retrieved)
            self.assertEqual(output.read_bytes(), b'{"count":4,"mean":2.5,"sum":10}\n')
        with self.assertRaises(FileExistsError):
            example.calculate(fixture, self.path / "first.json")
        for line in (EXAMPLE / "SHA256SUMS").read_text().splitlines():
            expected, name = line.split()
            self.assertEqual(hashlib.sha256((EXAMPLE / name).read_bytes()).hexdigest(), expected)

    def test_example_rejects_wrong_fixture_and_result_bytes(self):
        for data in (b"value\n1\n2\n3\n5\n", b"value\n1\n2\n3\n4\n\n", b"x" * 129):
            fixture = self.path / "bad.csv"
            fixture.write_bytes(data)
            with self.assertRaises(ValueError):
                example.calculate(fixture, self.path / "bad.json")
        local = self.path / "local.json"
        local.write_bytes(example.EXPECTED)
        for data in (b'{"sum":10,"mean":2.5,"count":4}\n', b'{"count":4,"mean":2.5,"sum":11}\n', b"x" * 129):
            retrieved = self.path / "retrieved.json"
            retrieved.write_bytes(data)
            with self.assertRaises(ValueError):
                example.verify(local, retrieved)

    def test_probe_never_claims_provider_access_or_deadline(self):
        from unittest.mock import patch
        completed = subprocess.CompletedProcess([], 0, stdout="test-version\n", stderr="")
        with patch.object(probe.subprocess, "run", return_value=completed), \
                patch.object(probe, "version", return_value="sdk-test"), \
                patch.object(probe.os, "geteuid", return_value=1000):
            facts = probe.probe("aws", self.path)
        self.assertIn("identity", facts["unverified_checks"])
        self.assertIn("deadline", facts["unverified_checks"])
        self.assertGreater(facts["resources"]["cpus"], 0)
        self.assertTrue(facts["project_directory_writable"])


if __name__ == "__main__":
    unittest.main()
