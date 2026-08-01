import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SourcePolicyTests(unittest.TestCase):
    def test_persistent_buckets_are_protected(self):
        module = (ROOT / "tofu/modules/gcp-bucket/main.tf").read_text()
        bootstrap = (ROOT / "tofu/gcp/bootstrap/main.tf").read_text()
        self.assertIn("force_destroy               = false", module)
        self.assertIn("prevent_destroy = true", module)
        self.assertIn("public_access_prevention    = \"enforced\"", module)
        self.assertIn("force_destroy               = false", bootstrap)
        self.assertIn("prevent_destroy = true", bootstrap)

    def test_storage_identities_are_keyless_and_impersonated(self):
        storage = (ROOT / "tofu/gcp/storage/main.tf").read_text()
        self.assertIn('resource "google_service_account_iam_member" "admin_impersonates_data_publisher"', storage)
        self.assertIn('resource "google_service_account_iam_member" "admin_impersonates_training_runtime"', storage)
        self.assertIn('role               = "roles/iam.serviceAccountTokenCreator"', storage)
        self.assertNotIn("google_service_account_key", storage)
        self.assertIn('resource "google_storage_bucket_iam_binding" "bronze_legacy"', storage)
        self.assertIn("members  = []", storage)

    def test_compute_source_has_delete_runtime_and_no_ray_ports(self):
        module = (ROOT / "tofu/modules/gcp-training-node/main.tf").read_text()
        network = (ROOT / "tofu/gcp/network/main.tf").read_text()
        self.assertIn('instance_termination_action = "DELETE"', module)
        self.assertIn("max_run_duration", module)
        self.assertIn("var.workspace_disk_enabled == false", module)
        self.assertNotIn("6379", network)
        self.assertNotIn('"0.0.0.0/0"', network)
        self.assertIn('"35.235.240.0/20"', network)

    def test_no_routine_persistent_destroy_target(self):
        makefile = (ROOT / "Makefile").read_text()
        self.assertNotIn("gcp-storage-down:", makefile)
        self.assertNotIn("gcp-bootstrap-down:", makefile)

    def test_clock_check_accepts_systemd_synchronization_marker(self):
        account_check = (ROOT / "scripts/gcp/account_check.sh").read_text()
        self.assertIn(
            "[[ -e /run/systemd/timesync/synchronized ]]", account_check
        )
        self.assertNotIn("path.read_text()", account_check)


if __name__ == "__main__":
    unittest.main()
