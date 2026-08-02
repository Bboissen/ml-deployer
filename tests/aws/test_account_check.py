import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("aws_account_check", ROOT / "scripts/aws/account_check.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AccountCheckTests(unittest.TestCase):
    def test_manual_evidence_is_a_blocker(self):
        audit = MODULE.Audit()
        audit.add("manual", "MANUAL_EVIDENCE_REQUIRED", "not confirmed")
        self.assertTrue(audit.failed)

    def test_warning_is_not_a_false_failure(self):
        audit = MODULE.Audit()
        audit.add("inventory", "WARN", "review required")
        self.assertFalse(audit.failed)

    def test_aws_commands_are_read_only(self):
        source = (ROOT / "scripts/aws/account_check.py").read_text()
        forbidden = (
            "run-instances",
            "create-bucket",
            "create-role",
            "request-service-quota-increase",
            "create-budget",
            "create-anomaly",
            "delete-",
            "terminate-instances",
        )
        for command in forbidden:
            with self.subTest(command=command):
                self.assertNotIn(f'"{command}"', source)


if __name__ == "__main__":
    unittest.main()
