#!/usr/bin/env bash
# Bounded, credential-free tests. Retain logs/fixtures below ignored evidence/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
exec "${WORKSPACE_PYTHON:-python3}" - <<'PY'
import datetime as dt
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path.cwd()
ARTIFACTS = ROOT / "evidence/aws/tests/storage" / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + str(os.getpid()))
ARTIFACTS.mkdir(parents=True)
ENV = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", WORKSPACE_PYTHON=sys.executable)


def native(root_name):
    data_dir = os.environ.get("AWS_STORAGE_" + root_name.upper() + "_TF_DATA_DIR", str(ARTIFACTS / (root_name + "-tofu-data")))
    env = {k: v for k, v in ENV.items() if not k.startswith(("AWS_", "TF_VAR_", "TF_CLI_ARGS")) and k not in ("TF_WORKSPACE", "TF_CLI_CONFIG_FILE")}
    env.update(TF_DATA_DIR=data_dir, AWS_EC2_METADATA_DISABLED="true")
    commands = [
        ("init", ["init", "-backend=false", "-input=false", "-lockfile=readonly", "-no-color"]),
        ("test", ["test", "-test-directory=../../../tests/aws/" + root_name, "-no-color", "-json", "-verbose"]),
    ]
    if root_name == "runner":
        commands[1][1].append("-var-file=terraform.tfvars.example")
    for name, args in commands:
        log = ARTIFACTS / (root_name + "-" + name + ".log")
        with log.open("w") as stream:
            result = subprocess.run(["tofu", "-chdir=infra/aws/" + root_name, *args], env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
        if result.returncode:
            raise RuntimeError("native " + root_name + " " + name + " failed: " + str(log.relative_to(ROOT)))
    events = [json.loads(line) for line in log.read_text().splitlines()]
    return {event["@testrun"]: event["test_plan"] for event in events if event.get("type") == "test_plan"}


class Preparation(unittest.TestCase):
    def setUp(self):
        self.root = ARTIFACTS / self.id().rsplit(".", 1)[-1]
        self.root.mkdir()
        for name in ("infra/aws/platform/provider.tf", "scripts/aws/workspace-target.sh", "scripts/aws/workspace_target.py", "scripts/aws/workspace-storage.sh", "scripts/aws/workspace-config.py", "scripts/workspace/validate.py", "shared/workspace/schema.json", "shared/workspace/toolbox.json"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        config = json.loads((ROOT / "infra/aws/targets.example.json").read_text())
        self.target = config["targets"]["aws-personal"]
        self.target["inventory"]["resource_prefix"] = "ml-infra"
        self.bucket = self.target["inventory"]["buckets"][0]
        (self.root / "evidence/aws").mkdir(parents=True)
        (self.root / "evidence/aws/targets.json").write_text(json.dumps(config))
        (self.root / "native-config").write_text("[profile personal-temporary]\ncredential_process = approved-existing-login\n")
        (self.root / "native-credentials").write_text("")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "aws"
        fake.write_text('''#!/usr/bin/env python3
import os,sys,json
args=sys.argv[1:]
with open(os.environ['FAKE_CALLS'],'a') as stream: stream.write(json.dumps(args)+'\\n')
if 'get-caller-identity' in args:
 print(json.dumps({'account':'111111111111','arn':'arn:aws:sts::111111111111:assumed-role/WorkspaceOperator/offline'}));sys.exit(0)
if os.environ.get('FAKE_FAILURE'):
 print('AccessDenied SENTINEL_SECRET',file=sys.stderr);sys.exit(254)
responses={
 'get-bucket-location':{'LocationConstraint':None},
 'get-bucket-versioning':{'Status':'Enabled'},
 'get-public-access-block':{'PublicAccessBlockConfiguration':{k:True for k in ('BlockPublicAcls','BlockPublicPolicy','IgnorePublicAcls','RestrictPublicBuckets')}},
 'get-bucket-ownership-controls':{'OwnershipControls':{'Rules':[{'ObjectOwnership':'BucketOwnerEnforced'}]}},
 'get-bucket-encryption':{'ServerSideEncryptionConfiguration':{'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'AES256'},'BucketKeyEnabled':False}]}},
}
value=responses[args[1]]
if os.environ.get('FAKE_UNPROTECTED') and args[1]=='get-bucket-versioning':value={'Status':'Suspended'}
print(json.dumps(value))
''')
        fake.chmod(0o700)
        git = self.bin / "git"
        git.write_text("#!/usr/bin/env bash\nif [[ \"$1\" == rev-parse ]]; then printf '%s\\n' 0000000000000000000000000000000000000000; fi\n")
        git.chmod(0o700)
        self.env = {k: v for k, v in ENV.items() if not k.startswith(("AWS_", "TF_VAR_", "TF_CLI_ARGS")) and k not in ("TF_DATA_DIR", "TF_WORKSPACE", "TF_CLI_CONFIG_FILE", "BOTO_CONFIG")}
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"], AWS_CONFIG_FILE=str(self.root / "native-config"),
                        AWS_SHARED_CREDENTIALS_FILE=str(self.root / "native-credentials"), FAKE_CALLS=str(self.root / "calls"))

    def cli(self, *args, success=True, **env):
        result = subprocess.run(["bash", "scripts/aws/workspace-storage.sh", *args], cwd=self.root, env={**self.env, **env}, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0 if success else 2, result.stdout + result.stderr)
        self.assertNotIn("SENTINEL_SECRET", result.stdout + result.stderr)
        if success:
            return self.root / json.loads(result.stdout)["evidence_directory"]
        return result

    def prepare(self, *args, **kwargs):
        return self.cli("prepare", "aws-personal", "--ml-project-name", "fraud-detection", "--workspace-name", "dev-01", *args, **kwargs)

    def inspect(self, **kwargs):
        assignment = self.root / "assignment.json"
        assignment.write_text(json.dumps({"bucket_name": self.bucket, "ownership": "external", "resource_address": "", "state_key": ""}))
        return self.cli("inspect", "aws-personal", "--ml-project-name", "fraud-detection", "--assignment", str(assignment), **kwargs)

    def test_unassigned_auto_is_offline_stable_and_scoped(self):
        first, second = self.prepare(), self.prepare()
        a, b = [json.loads((directory / "storage-preparation.json").read_text()) for directory in (first, second)]
        self.assertEqual(a, b)
        self.assertFalse(a["compute_enabled"] or a["deployment_authorized"] or a["cloud_resources_observed"])
        self.assertNotEqual(first, second)
        self.assertFalse((self.root / "calls").exists())
        self.assertIn("/projects/fraud-detection/workspaces/fraud-detection-dev-01/output/", a["storage"]["output_uri"])

    def test_existing_requires_assignment_and_never_falls_back(self):
        self.prepare("--storage-mode", "existing", success=False)
        self.inspect(success=False, FAKE_FAILURE="1")
        self.assertFalse(list((self.root / "evidence/aws").rglob("storage-preparation.json")))

    def test_inspected_existing_auto_reuses_same_bucket(self):
        inspection = self.inspect()
        path = inspection / "assignment-inspection.json"
        prepared = self.prepare("--assignment", str(path))
        value = json.loads((prepared / "storage-preparation.json").read_text())
        self.assertEqual(value["storage_action"], "reference-assignment")
        self.assertTrue(value["storage"]["data_uri"].startswith("s3://" + self.bucket + "/"))
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        metadata = [args for args in calls if "get-caller-identity" not in args]
        self.assertEqual(len(metadata), 5)
        for args in metadata:
            self.assertEqual(args[args.index("--expected-bucket-owner") + 1], "111111111111")
        self.prepare("--storage-mode", "create", "--assignment", str(path), success=False)

    def test_unprotected_assignment_is_rejected(self):
        self.inspect(success=False, FAKE_UNPROTECTED="1")

    def test_unknown_target_and_ambiguous_project_name_are_rejected(self):
        self.cli("prepare", "aws-unknown", "--ml-project-name", "fraud-detection", "--workspace-name", "dev-01", success=False)
        for name in ("Fraud Detection", "fraud_detection", "../../fraud", "a" * 33):
            self.cli("prepare", "aws-personal", "--ml-project-name", name, "--workspace-name", "dev-01", success=False)
        self.prepare("--workspace-name", "a" * 48, success=False)
        self.assertFalse((self.root / "calls").exists())

    def test_assignment_hash_target_and_staleness_are_checked(self):
        path = self.inspect() / "assignment-inspection.json"
        original = json.loads(path.read_text())
        for key, value in (("review_sha256", "a" * 64), ("aws_region", "us-west-2"), ("observed_at", "2000-01-01T00:00:00+00:00")):
            bad = dict(original, **{key: value})
            if key != "review_sha256":
                bad.pop("review_sha256")
                bad["review_sha256"] = hashlib.sha256((json.dumps(bad, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()
            changed = self.root / (key + ".json")
            changed.write_text(json.dumps(bad))
            self.prepare("--assignment", str(changed), success=False)

    def test_resolved_request_uses_unchanged_common_validator_and_hash(self):
        prepared = self.prepare()
        storage = json.loads((prepared / "request-storage.json").read_text())
        request = json.loads((ROOT / "shared/workspace/fixtures/aws-request.json").read_text())
        request.update(account_scope="111111111111", region="us-east-1", workspace_id="fraud-detection-dev-01", storage=storage)
        path = self.root / "request.json"
        path.write_text(json.dumps(request))
        result = self.prepare("--request", str(path))
        metadata = json.loads((result / "storage-preparation.json").read_text())
        self.assertEqual(metadata["request_sha256"], hashlib.sha256((json.dumps(request, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest())
        self.assertFalse(list(result.glob("*handoff*")))
        for mutation in ({"credentials": "SENTINEL_SECRET"}, {"storage": dict(storage, output_uri=storage["data_uri"])}, {"workspace_id": "fraud-detection-dev-02"}):
            path.write_text(json.dumps(dict(request, **mutation)))
            self.prepare("--request", str(path), success=False)


def evaluate(documents, action, resource, context):
    # Deliberately limited to the operators emitted by this policy template.
    # It does not model account-level IAM, SCPs, endpoint policies or live access.
    allowed = False
    for document in documents:
        for statement in document["Statement"]:
            key = "Action" if "Action" in statement else "NotAction"
            matches = any(fnmatch.fnmatchcase(action.lower(), pattern.lower()) for pattern in statement[key])
            if matches == (key == "NotAction"):
                continue
            key = "Resource" if "Resource" in statement else "NotResource"
            def expand(pattern):
                return pattern.replace("${aws:PrincipalTag/workspace_id}", context["workspace_id"])
            matches = any(fnmatch.fnmatchcase(resource, expand(pattern)) for pattern in statement[key])
            if matches == (key == "NotResource"):
                continue
            conditions = True
            for operator, entries in statement.get("Condition", {}).items():
                if operator not in ("StringLike", "StringNotLike", "Bool"):
                    raise AssertionError("unsupported test policy condition")
                for field, patterns in entries.items():
                    if isinstance(patterns, str):
                        patterns = [patterns]
                    matches = field in context and any(fnmatch.fnmatchcase(context[field], expand(pattern)) for pattern in patterns)
                    conditions = conditions and (not matches if operator == "StringNotLike" else matches)
            if not conditions:
                continue
            if statement["Effect"] == "Deny":
                return "Deny"
            allowed = True
    return "Allow" if allowed else "ImplicitDeny"


def policies_and_ordering(platform, runner):
    p = platform["unassigned_auto_creates_one_versioned_private_project_bucket"]
    r = runner["scoped_identity_and_native_temporary_profile"]
    def values(plan, address):
        return next(resource["values"] for resource in plan["planned_values"]["root_module"]["resources"] if resource["address"] == address)
    boundary = json.loads(values(p, 'aws_iam_policy.project_workspace_boundary["fraud-detection"]')["policy"])
    effective = json.loads(values(r, 'aws_iam_role_policy.workspace_storage["fraud-detection-dev-01"]')["policy"])
    management = json.loads(values(p, "aws_iam_policy.session_manager")["policy"])
    # Normalize AWS JSON's string/list shorthand for the limited evaluator.
    for doc in (boundary, effective, management):
        for statement in doc["Statement"]:
            for key in ("Action", "NotAction", "Resource", "NotResource"):
                if key in statement and isinstance(statement[key], str):
                    statement[key] = [statement[key]]
    # Rebind the project test boundary to the runner fixture's invented bucket.
    bucket = next(s["Resource"][0] for s in boundary["Statement"] if s["Sid"] == "ReadWorkloadBucketLocation")
    boundary = json.loads(json.dumps(boundary).replace(bucket, "arn:aws:s3:::offline-project-example"))
    (ARTIFACTS / "rendered-policy-fixtures.json").write_text(json.dumps({"boundary": boundary, "effective": effective, "management": management}, indent=2))
    scope = "arn:aws:s3:::offline-project-example"
    data = scope + "/projects/fraud-detection/data/"
    output = scope + "/projects/fraud-detection/workspaces/fraud-detection-dev-01/output/"
    cases = []
    for action in ("s3:GetObject", "s3:GetObjectVersion"):
        cases += [(action, data + "part-01.csv", {}, True), (action, output + "result.json", {}, True)]
    for action in ("s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"):
        cases += [(action, output + "nested/result.json", {}, True), (action, data + "part-01.csv", {}, False)]
    for action in ("s3:ListBucket", "s3:ListBucketVersions"):
        for prefix, accepted in (("projects/fraud-detection/data/", True), ("projects/fraud-detection/data/part-", True),
                                 ("projects/fraud-detection/workspaces/fraud-detection-dev-01/output/", True),
                                 ("", False), ("projects/fraud-detection/", False), ("projects/fraud-detection/workspaces/fraud-detection-dev-02/output/", False)):
            cases.append((action, scope, {"s3:prefix": prefix}, accepted))
        cases.append((action, scope, {}, False))
    for resource in (scope + "/projects/other-project/data/x", output.replace("dev-01", "dev-02") + "x",
                     scope + "/unrelated/x", "arn:aws:s3:::another-project/x", "arn:aws:s3:::replace-ml-infra-aws-state-unique/aws/state"):
        for action in ("s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"):
            cases.append((action, resource, {}, False))
    for action in ("s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketPolicy", "s3:ListBucketMultipartUploads",
                   "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory", "ssm:DescribeParameters",
                   "iam:TagRole", "iam:PutRolePolicy", "iam:DeleteRolePermissionsBoundary", "sts:AssumeRole",
                   "scheduler:DeleteSchedule", "lambda:UpdateFunctionCode", "ec2:ModifyInstanceAttribute", "ec2:CreateTags", "kms:Decrypt"):
        cases.append((action, output + "x", {}, False))
    for action in ("ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"):
        cases.append((action, "*", {}, True))
    cases.append(("s3:GetBucketLocation", scope, {}, True))
    cases += [("s3:GetObject", data + "x", {"aws:SecureTransport": "false"}, False),
              ("s3:PutObject", output + "x", {"aws:SecureTransport": "false"}, False)]
    for action, resource, extra, accepted in cases:
        context = dict({"aws:SecureTransport": "true"}, **extra, workspace_id="fraud-detection-dev-01")
        identity_result = evaluate([effective, management], action, resource, context)
        boundary_result = evaluate([boundary], action, resource, context)
        assert (identity_result == boundary_result == "Allow") == accepted, (action, resource, extra, identity_result, boundary_result)
        if not accepted:
            # Explicit denial remains when a hypothetical attached or direct
            # session resource policy grants that same forbidden operation.
            assert identity_result == boundary_result == "Deny", (action, resource)
    resources = {item["address"]: item for item in r["configuration"]["root_module"]["resources"]}
    for profile, dependencies in (("aws_iam_instance_profile.workspace", ("aws_iam_role_policy.workspace_storage", "aws_iam_role_policy_attachment.workspace_ssm")),
                                  ("aws_iam_instance_profile.runtime", ("aws_iam_role_policy.runtime", "aws_iam_role_policy_attachment.ssm"))):
        assert set(dependencies).issubset(resources[profile]["depends_on"]), profile
    assert "aws_iam_instance_profile.runtime.name" in resources["aws_instance.runner"]["expressions"]["iam_instance_profile"]["references"]
    assert not any(item["type"].startswith("aws_s3_") for item in resources.values() if item["mode"] == "managed")
    # Retention safeguards are literal lifecycle controls, absent from plan JSON.
    for path in ("infra/aws/platform/project-storage.tf", "infra/aws/platform/storage.tf", "infra/aws/bootstrap/main.tf"):
        assert "prevent_destroy = true" in (ROOT / path).read_text(), path
        assert "force_destroy = true" not in (ROOT / path).read_text(), path
    return len(cases)


try:
    with (ARTIFACTS / "preparation-tests.log").open("w") as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Preparation))
    if not result.wasSuccessful():
        raise RuntimeError("preparation tests failed")
    platform, runner = native("platform"), native("runner")
    count = policies_and_ordering(platform, runner)
    (ARTIFACTS / "result.json").write_text(json.dumps({"status": "passed", "preparation_tests": result.testsRun, "policy_cases": count,
                                                    "native_plan_tests": len(platform) + len(runner), "cloud_api_calls": False, "cloud_mutations": False}, indent=2))
    print("test-aws-workspace-storage: PASS (" + str(ARTIFACTS.relative_to(ROOT)) + ")")
except (Exception, KeyboardInterrupt) as error:
    (ARTIFACTS / "result.json").write_text(json.dumps({"status": "failed", "reason": str(error)}, indent=2))
    print("test-aws-workspace-storage: FAIL (" + str(ARTIFACTS.relative_to(ROOT)) + ")", file=sys.stderr)
    sys.exit(1)
PY
