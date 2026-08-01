import copy
import unittest

from plan_policy import PolicyError, validate


def change(resource_type, after, actions=None, address=None):
    return {"type": resource_type, "address": address or resource_type + ".fixture", "change": {"actions": actions or ["create"], "after": after}}


class PlanPolicyTests(unittest.TestCase):
    def setUp(self):
        self.vm = change(
            "google_compute_instance",
            {
                "project": "example-project",
                "machine_type": "e2-micro",
                "metadata": {"profile": "smoke-free"},
                "scheduling": [{"instance_termination_action": "DELETE", "max_run_duration": [{"seconds": 2700}]}],
                "attached_disk": [],
            },
        )

    def assert_rejected(self, plan):
        with self.assertRaises(PolicyError):
            validate(plan, "compute")

    def test_accepts_single_bounded_vm(self):
        validate({"resource_changes": [self.vm]}, "compute")

    def test_rejects_two_vms(self):
        self.assert_rejected({"resource_changes": [self.vm, copy.deepcopy(self.vm)]})

    def test_rejects_wrong_project(self):
        bad = copy.deepcopy(self.vm)
        bad["change"]["after"]["project"] = "wrong-project"
        self.assert_rejected({"resource_changes": [bad]})

    def test_rejects_missing_runtime_and_bad_termination(self):
        for field, value in (("max_run_duration", None), ("instance_termination_action", "STOP")):
            bad = copy.deepcopy(self.vm)
            if value is None:
                bad["change"]["after"]["scheduling"][0].pop(field)
            else:
                bad["change"]["after"]["scheduling"][0][field] = value
            self.assert_rejected({"resource_changes": [bad]})

    def test_rejects_public_ingress_static_ip_key_and_public_bucket(self):
        fixtures = [
            change("google_compute_firewall", {"source_ranges": ["0.0.0.0/0"]}),
            change("google_compute_address", {}),
            change("google_service_account_key", {}),
            change("google_storage_bucket_iam_member", {"member": "allUsers"}),
        ]
        for fixture in fixtures:
            self.assert_rejected({"resource_changes": [fixture]})

    def test_rejects_bucket_policy_and_persistent_compute_delete(self):
        bucket = change("google_storage_bucket", {"location": "EU", "storage_class": "NEARLINE", "force_destroy": True, "public_access_prevention": "inherited"})
        self.assert_rejected({"resource_changes": [bucket]})
        delete = change("google_compute_network", {}, actions=["delete"])
        self.assert_rejected({"resource_changes": [delete]})

    def test_rejects_storage_role_crossovers_and_retention(self):
        trainer_write = change("google_storage_bucket_iam_member", {"bucket": "project-bronze", "member": "serviceAccount:training-runtime@example", "role": "roles/storage.objectCreator"})
        publisher_state = change("google_storage_bucket_iam_member", {"bucket": "project-tofu-state", "member": "serviceAccount:data-publisher@example", "role": "roles/storage.objectViewer"})
        retention = change("google_storage_bucket", {"location": "US-CENTRAL1", "storage_class": "STANDARD", "force_destroy": False, "public_access_prevention": "enforced", "retention_policy": [{"is_locked": True}]})
        for fixture in (trainer_write, publisher_state, retention):
            self.assert_rejected({"resource_changes": [fixture]})

    def test_rejects_gpu_local_ssd_and_api_resources(self):
        for field in ("guest_accelerator", "scratch_disk"):
            bad = copy.deepcopy(self.vm)
            bad["change"]["after"][field] = [{"fixture": True}]
            self.assert_rejected({"resource_changes": [bad]})
        self.assert_rejected({"resource_changes": [change("google_project_service", {})]})

    def test_storage_bucket_requires_private_regional_controls(self):
        bucket = {
            "project": "example-project",
            "name": "example-project-bronze",
            "location": "US-CENTRAL1",
            "storage_class": "STANDARD",
            "force_destroy": False,
            "public_access_prevention": "enforced",
            "uniform_bucket_level_access": True,
            "autoclass": [],
            "cors": [],
            "encryption": [],
            "requester_pays": None,
            "retention_policy": [],
            "soft_delete_policy": [{"retention_duration_seconds": 604800}],
            "lifecycle_rule": [],
            "versioning": [{"enabled": True}],
            "labels": {"project": "p", "owner": "o", "environment": "e", "managed_by": "opentofu", "layer": "bronze"},
        }
        validate({"resource_changes": [change("google_storage_bucket", bucket, address="module.bronze.google_storage_bucket.this")]}, "storage")
        for field, value in (
            ("uniform_bucket_level_access", False),
            ("autoclass", [{"enabled": True}]),
            ("cors", [{"origin": ["*"]}]),
            ("requester_pays", True),
            ("soft_delete_policy", []),
            ("versioning", [{"enabled": False}]),
        ):
            bad = copy.deepcopy(bucket)
            bad[field] = value
            with self.assertRaises(PolicyError):
                validate({"resource_changes": [change("google_storage_bucket", bad, address="module.bronze.google_storage_bucket.this")]}, "storage")

    def test_rejects_acl_and_authoritative_bucket_iam_policy(self):
        for resource_type in ("google_storage_bucket_acl", "google_storage_bucket_iam_policy"):
            self.assert_rejected({"resource_changes": [change(resource_type, {})]})

    def test_only_empty_fixed_legacy_bucket_bindings_are_allowed(self):
        binding = change(
            "google_storage_bucket_iam_binding",
            {
                "bucket": "example-project-bronze",
                "role": "roles/storage.legacyBucketOwner",
                "members": [],
            },
            address='google_storage_bucket_iam_binding.bronze_legacy["roles/storage.legacyBucketOwner"]',
        )
        validate({"resource_changes": [binding]}, "storage")
        for field, value in (("role", "roles/storage.objectAdmin"), ("members", ["allUsers"]), ("bucket", "wrong")):
            bad = copy.deepcopy(binding)
            bad["change"]["after"][field] = value
            with self.assertRaises(PolicyError):
                validate({"resource_changes": [bad]}, "storage")

    def test_artifact_lifecycle_is_limited_to_temporary_prefixes(self):
        artifact = {
            "project": "example-project",
            "name": "example-project-artifacts",
            "location": "US-CENTRAL1",
            "storage_class": "STANDARD",
            "force_destroy": False,
            "public_access_prevention": "enforced",
            "uniform_bucket_level_access": True,
            "autoclass": [],
            "cors": [],
            "encryption": [],
            "requester_pays": None,
            "retention_policy": [],
            "soft_delete_policy": [{"retention_duration_seconds": 604800}],
            "versioning": [{"enabled": False}],
            "labels": {"project": "p", "owner": "o", "environment": "e", "managed_by": "opentofu", "layer": "artifacts"},
            "lifecycle_rule": [
                {
                    "action": [{"type": "Delete"}],
                    "condition": [{"age": 7, "matches_prefix": ["artifacts/tmp/", "artifacts/runs/unaccepted/"]}],
                }
            ],
        }
        validate({"resource_changes": [change("google_storage_bucket", artifact, address="module.artifacts.google_storage_bucket.this")]}, "storage")
        artifact["lifecycle_rule"][0]["condition"][0]["matches_prefix"] = [""]
        with self.assertRaises(PolicyError):
            validate({"resource_changes": [change("google_storage_bucket", artifact, address="module.artifacts.google_storage_bucket.this")]}, "storage")


if __name__ == "__main__":
    unittest.main()
