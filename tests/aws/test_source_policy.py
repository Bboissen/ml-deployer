import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class SourcePolicyTests(unittest.TestCase):
    def test_all_provider_roots_are_separate_and_backend_safe(self):
        for root in ("bootstrap", "storage", "network", "training-node", "spot-runner"):
            with self.subTest(root=root):
                path = ROOT / "tofu/aws" / root
                self.assertTrue((path / "versions.tf").is_file())
                self.assertTrue((path / "main.tf").is_file())
                self.assertTrue((path / "variables.tf").is_file())
        self.assertNotIn('backend "s3"', (ROOT / "tofu/aws/bootstrap/versions.tf").read_text())
        for root in ("storage", "network", "training-node", "spot-runner"):
            self.assertIn('backend "s3" {}', (ROOT / "tofu/aws" / root / "versions.tf").read_text())

    def test_goals_01_02_have_no_aws_resources(self):
        for path in (ROOT / "tofu/aws").rglob("*.tf"):
            with self.subTest(path=path):
                self.assertNotIn('resource "aws_', path.read_text())

    def test_mutation_targets_fail_closed(self):
        makefile = (ROOT / "Makefile").read_text()
        gate = (ROOT / "scripts/aws/mutation_gate.sh").read_text()
        for target in ("aws-authorize:", "aws-up:", "aws-down:", "aws-spot-cancel:"):
            self.assertIn(target, makefile)
        self.assertIn("REFUSED", gate)
        self.assertNotIn("tofu apply", makefile)
        self.assertNotIn("tofu destroy", makefile)
        self.assertNotIn("aws s3", makefile)

    def test_aws_runtime_and_audits_are_ignored(self):
        ignore = (ROOT / ".gitignore").read_text()
        self.assertIn(".aws-runtime/", ignore)
        self.assertIn("artifacts/audits/*.json", ignore)
        self.assertIn("!configs/aws/constants.env", ignore)

    def test_docs_for_console_and_image_split_exist(self):
        account = (ROOT / "docs/account-setup-aws.md").read_text()
        image = (ROOT / "docs/image-policy-aws.md").read_text()
        self.assertIn("Do not create in the console", account)
        self.assertIn("aws login", account)
        self.assertIn("nvidia-smi", image)
        self.assertIn("Canonical", image)


if __name__ == "__main__":
    unittest.main()
