import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = json.loads((ROOT / "configs/aws/machine_profiles.json").read_text())


class ProfileContractTests(unittest.TestCase):
    def test_profile_name_matches_key_and_common_safety_controls(self):
        for name, profile in PROFILES.items():
            with self.subTest(profile=name):
                self.assertEqual(name, profile["profile_name"])
                self.assertEqual(profile["architecture"], "x86_64")
                self.assertEqual(profile["root_volume_type"], "gp3")
                self.assertTrue(profile["deadline_schedule_enabled"])
                self.assertTrue(profile["local_termination_fallback_enabled"])
                self.assertTrue(profile["delete_workspace_on_terminal_state"])
                self.assertFalse(profile["allow_ray"])
                self.assertGreater(profile["max_run_duration_minutes"], 0)
                self.assertIsNone(profile["max_estimated_cost"])

    def test_cpu_and_gpu_profiles_use_distinct_reviewed_image_families(self):
        cpu = PROFILES["cpu-memory-plan"]
        gpu = PROFILES["gpu-single-plan"]
        self.assertIn("canonical/ubuntu/server/24.04", cpu["ami_parameter_name"])
        self.assertFalse(cpu["allow_gpu"])
        self.assertEqual(cpu["accelerator_count"], 0)
        self.assertIn("base-oss-nvidia-driver-gpu-ubuntu-24.04", gpu["ami_parameter_name"])
        self.assertTrue(gpu["allow_gpu"])
        self.assertEqual(gpu["accelerator_count"], 1)

    def test_free_tier_smoke_remains_unresolved_until_live_discovery(self):
        smoke = PROFILES["smoke-free"]
        self.assertEqual(smoke["instance_type"], "DISCOVER_FREE_TIER_ELIGIBLE")
        self.assertEqual(smoke["status"], "DISCOVERY_REQUIRED")

    def test_direct_profiles_do_not_preserve_workspace(self):
        for name, profile in PROFILES.items():
            if profile["execution_mode"] == "DIRECT_INSTANCE":
                with self.subTest(profile=name):
                    self.assertFalse(profile["workspace_preserve_on_replacement"])
                    self.assertEqual(profile["max_recovery_attempts"], 0)


if __name__ == "__main__":
    unittest.main()
