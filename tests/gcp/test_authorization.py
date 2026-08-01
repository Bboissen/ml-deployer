import stat
import tempfile
import unittest
from pathlib import Path

from authorization import AuthorizationError, private_write, sha256, validate


class AuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.plan = self.root / "plan.tfplan"
        self.plan.write_bytes(b"reviewed-plan")
        self.now = 1_800_000_000
        self.receipt = {
            "authorization_id": "test-auth",
            "project_id": "example-project",
            "root": "tofu/gcp/training-node",
            "profile": "smoke-free",
            "plan_sha256": sha256(self.plan),
            "expected_changes": {"add": 1, "change": 0, "destroy": 0},
            "billing_account_id": "billing-id",
            "operator_identity": "operator@example.com",
            "max_estimated_cost": 1.0,
            "issued_at": self.now - 60,
            "expires_at": self.now + 60,
            "one_use_nonce": "nonce",
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_exact_bindings_pass(self):
        validate(
            self.receipt,
            root="tofu/gcp/training-node",
            profile="smoke-free",
            plan=self.plan,
            now=self.now,
            expected_counts={"add": 1, "change": 0, "destroy": 0},
            billing_account_id="billing-id",
        )

    def test_expiry_project_root_profile_plan_and_destroy_rejected(self):
        mutations = [
            ("expires_at", self.now),
            ("project_id", "wrong"),
            ("root", "tofu/gcp/storage"),
            ("profile", "smoke-paid"),
            ("plan_sha256", "0" * 64),
            ("expected_changes", {"add": 0, "change": 0, "destroy": 1}),
            ("billing_account_id", "wrong-billing"),
            ("max_estimated_cost", -1),
        ]
        for key, value in mutations:
            bad = dict(self.receipt)
            bad[key] = value
            with self.assertRaises(AuthorizationError):
                validate(
                    bad,
                    root="tofu/gcp/training-node",
                    profile="smoke-free",
                    plan=self.plan,
                    now=self.now,
                    expected_counts={"add": 1, "change": 0, "destroy": 0},
                    billing_account_id="billing-id",
                )

    def test_private_write_is_mode_0600_and_one_use(self):
        path = self.root / "receipt.json"
        private_write(path, self.receipt)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError):
            private_write(path, self.receipt)


if __name__ == "__main__":
    unittest.main()
