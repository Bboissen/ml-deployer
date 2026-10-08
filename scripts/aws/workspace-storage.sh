#!/usr/bin/env bash
# Provider-owned storage preparation. prepare is entirely offline; inspect only
# reads reviewed bucket metadata through the milestone-A named target boundary.
set -euo pipefail
exec "${WORKSPACE_PYTHON:-python3}" - "$@" <<'PY'
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path.cwd().resolve()
BASE = ROOT / "evidence/aws"


class Failure(ValueError):
    pass


def require(ok, reason):
    if not ok:
        raise Failure(reason)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def load(path):
    require(Path(path).stat().st_size <= 1024 * 1024, "input exceeds one MiB")
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False, "nonfinite JSON"))


def fields(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected), "missing/unknown fields")


def call(argv, timeout=40):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, "selected-target command failed; no fallback creation")
    require(len(result.stdout) <= 1024 * 1024, "metadata response exceeds one MiB")
    return json.loads(result.stdout, object_pairs_hook=pairs)


def target(name):
    # list validates the complete local target configuration without credentials
    # or account APIs. Hash the exact selected target into each preparation.
    listing = call(["bash", "scripts/aws/workspace-target.sh", "list"], 10)
    require(any(t["target"] == name for t in listing), "unknown explicit target")
    t = load(BASE / "targets.json")["targets"][name]
    require(not t["region"].startswith(("cn-", "us-gov-")), "workspace B currently supports the commercial AWS partition")
    require(re.fullmatch(r"[a-z][a-z0-9-]{2,23}", t["inventory"]["resource_prefix"]), "reviewed infrastructure prefix is invalid")
    return t


def source_binding():
    revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
    require(revision.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", revision.stdout.strip()), "source revision unavailable")
    paths = [path for directory in (ROOT / "infra/aws", ROOT / "scripts/aws")
             for path in directory.rglob("*") if path.is_file() and path.suffix in (".tf", ".tftpl", ".hcl", ".sh")]
    paths += [ROOT / name for name in ("scripts/workspace/validate.py", "shared/workspace/schema.json", "shared/workspace/toolbox.json")]
    require(not any(path.is_symlink() for path in paths), "source symlink rejected")
    manifest = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}
    return {"revision": revision.stdout.strip(), "files": manifest, "files_sha256": digest(manifest)}


def assignment_base(value, t, slug):
    fields(value, ["bucket_name", "ownership", "resource_address", "state_key"])
    require(isinstance(value["bucket_name"], str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", value["bucket_name"]), "invalid assigned bucket name")
    require(value["bucket_name"] != t["backend"]["bucket"], "state cannot be workload storage")
    require(value["ownership"] in ("platform-managed", "external"), "unknown assignment ownership")
    if value["ownership"] == "external":
        require(value["resource_address"] == "" and value["state_key"] == "", "external storage is a reference, not an import")
    else:
        require(value["state_key"] == t["backend"]["platform_key"], "managed assignment state owner mismatch")
        require(value["resource_address"] in (f'aws_s3_bucket.project["{slug}"]', 'aws_s3_bucket.workload["data"]', 'aws_s3_bucket.workload["results"]'), "unreviewed managed resource address")
    return value


def store(directory, files):
    require(directory.is_relative_to(BASE), "output must be under evidence/aws/")
    require(not any(p.is_symlink() for p in [directory, *directory.parents] if p.is_relative_to(ROOT)), "evidence symlink rejected")
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    for name, value in files.items():
        with (directory / name).open("xb") as stream:
            stream.write(canonical(value))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "inspect"])
    parser.add_argument("target")
    parser.add_argument("--ml-project-name", required=True)
    parser.add_argument("--workspace-name")
    parser.add_argument("--storage-mode", choices=["auto", "create", "existing"], default="auto")
    parser.add_argument("--assignment", type=Path)
    parser.add_argument("--request", type=Path)
    args = parser.parse_args()
    slug = args.ml_project_name
    # Strict canonical spelling avoids lossy normalization/name collisions.
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}[a-z0-9]", slug), "ML project name must be canonical: 3-32 lowercase letters/digits/internal hyphens")
    t = target(args.target)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    directory = BASE / args.target / "storage" / slug / (stamp + "-" + str(os.getpid()))
    binding = {"target": args.target, "configuration_sha256": digest(t), "ml_project_name": slug, "source": source_binding()}
    if args.action == "inspect":
        require(args.assignment is not None and args.request is None and args.workspace_name is None, "inspect requires only a reviewed assignment description")
        assignment = assignment_base(load(args.assignment), t, slug)
        require(assignment["bucket_name"] in t["inventory"]["buckets"], "bucket is outside the named target's reviewed inventory")
        observations = {}
        started = time.monotonic()
        for api in ("get-bucket-location", "get-bucket-versioning", "get-public-access-block", "get-bucket-ownership-controls", "get-bucket-encryption"):
            require(time.monotonic() - started < 200, "bounded inspection expired")
            observations[api] = call(["bash", "scripts/aws/workspace-target.sh", "exec", args.target, "--", "aws", "s3api", api,
                                      "--bucket", assignment["bucket_name"], "--expected-bucket-owner", t["account_id"], "--output", "json"])
        location = observations["get-bucket-location"].get("LocationConstraint")
        location = "us-east-1" if location is None else "eu-west-1" if location == "EU" else location
        require(location == t["region"], "assigned bucket region mismatch")
        protections = {
            "versioning_enabled": observations["get-bucket-versioning"].get("Status") == "Enabled",
            "public_access_blocked": all(observations["get-public-access-block"].get("PublicAccessBlockConfiguration", {}).get(k) is True
                                         for k in ("BlockPublicAcls", "BlockPublicPolicy", "IgnorePublicAcls", "RestrictPublicBuckets")),
            "owner_enforced": observations["get-bucket-ownership-controls"].get("OwnershipControls", {}).get("Rules") == [{"ObjectOwnership": "BucketOwnerEnforced"}],
            "aes256_encryption": len(observations["get-bucket-encryption"].get("ServerSideEncryptionConfiguration", {}).get("Rules", [])) == 1
                and observations["get-bucket-encryption"]["ServerSideEncryptionConfiguration"]["Rules"][0].get("ApplyServerSideEncryptionByDefault") == {"SSEAlgorithm": "AES256"},
        }
        require(all(protections.values()), "assigned bucket protections unsupported or incomplete")
        receipt = dict(binding, assignment=assignment, aws_account_id=t["account_id"], aws_region=t["region"],
                       observed_at=dt.datetime.now(dt.timezone.utc).isoformat(), protections=protections, observations=observations)
        receipt["review_sha256"] = digest(receipt)
        store(directory, {"assignment-inspection.json": receipt})
    else:
        require(args.workspace_name is not None and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.workspace_name), "explicit canonical workspace suffix required")
        workspace_id = slug + "-" + args.workspace_name
        require(3 <= len(workspace_id) <= 48, "derived workspace ID exceeds interface 2.0.0 bounds")
        assignment = None
        if args.assignment:
            receipt = load(args.assignment)
            fields(receipt, [*binding, "assignment", "aws_account_id", "aws_region", "observed_at", "protections", "observations", "review_sha256"])
            review_hash = receipt.pop("review_sha256")
            require(review_hash == digest(receipt), "assignment inspection hash mismatch")
            require(all(receipt[k] == v for k, v in binding.items()) and receipt["aws_account_id"] == t["account_id"] and receipt["aws_region"] == t["region"], "assignment inspection target/project mismatch")
            observed = dt.datetime.fromisoformat(receipt["observed_at"])
            age = (dt.datetime.now(dt.timezone.utc) - observed).total_seconds()
            require(0 <= age <= 86400, "assignment inspection must be refreshed within 24 hours")
            fields(receipt["protections"], ["versioning_enabled", "public_access_blocked", "owner_enforced", "aes256_encryption"])
            require(all(v is True for v in receipt["protections"].values()), "assigned protections incomplete")
            assignment = dict(assignment_base(receipt["assignment"], t, slug), aws_account_id=t["account_id"],
                              aws_region=t["region"], review_sha256=review_hash, protections=receipt["protections"])
        require(args.storage_mode != "existing" or assignment is not None, "existing mode requires an inspected assignment")
        require(args.storage_mode != "create" or assignment is None or (assignment["ownership"] == "platform-managed" and assignment["resource_address"] == f'aws_s3_bucket.project["{slug}"]'), "create cannot adopt existing external/historical storage")
        suffix = hashlib.sha256(f'{t["account_id"]}/{t["region"]}/{slug}'.encode()).hexdigest()[:16]
        bucket = assignment["bucket_name"] if assignment else f"ml-{slug}-{suffix}"
        storage = {
            "data_uri": f"s3://{bucket}/projects/{slug}/data/",
            "output_uri": f"s3://{bucket}/projects/{slug}/workspaces/{workspace_id}/output/",
            "state_uri": f's3://{t["backend"]["bucket"]}/{t["backend"]["runner_prefix"]}{workspace_id}.tfstate',
        }
        receipt = dict(binding, workspace_id=workspace_id, storage_mode=args.storage_mode, storage=storage,
                       storage_action="reference-assignment" if assignment else "plan-new-empty-bucket",
                       cloud_resources_observed=False, compute_enabled=False, deployment_authorized=False,
                       operator_arn=t["operator_arn"], deployer_role_arn=t["deployment_role_arn"],
                       ownership=assignment["ownership"] if assignment else "platform-managed",
                       platform_state_key=t["backend"]["platform_key"])
        files = {
            "storage-preparation.json": receipt,
            # An entry to merge into the complete project map, never a replacement
            # tfvars file that silently removes other persistent projects.
            "platform-project-entry.json": {slug: {"ml_project_name": slug, "storage_mode": args.storage_mode, "assignment": assignment}},
            "request-storage.json": storage,
        }
        if args.request:
            # Validate closed shared records before writing any generated inputs.
            spec = importlib.util.spec_from_file_location("workspace_contract", ROOT / "scripts/workspace/validate.py")
            contract = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(contract)
            request = contract.load(args.request, "request")
            contract.request_semantics(request)
            require(request["provider"] == "aws" and request["account_scope"] == t["account_id"] and request["region"] == t["region"]
                    and request["workspace_id"] == workspace_id and request["storage"] == storage, "request does not match resolved project storage/target")
            receipt["request_sha256"] = contract.digest(request)
            prefix = t["inventory"]["resource_prefix"]
            files["workspace-identity-inputs.json"] = {"workspace_identity": {
                "ml_project_name": slug, "request": request, "bucket_name": bucket,
                "permissions_boundary_arn": f'arn:aws:iam::{t["account_id"]}:policy/{prefix}-ws-{slug}-boundary',
                "session_policy_arn": f'arn:aws:iam::{t["account_id"]}:policy/{prefix}-session-manager-minimal',
            }}
        store(directory, files)
    print(json.dumps({"status": "passed", "action": args.action, "evidence_directory": str(directory.relative_to(ROOT))}))


try:
    main()
except (Failure, ValueError, OSError, KeyError, TypeError, ImportError, subprocess.TimeoutExpired) as error:
    print("aws-workspace-storage: FAIL: " + (str(error) if isinstance(error, Failure) else type(error).__name__), file=sys.stderr)
    sys.exit(2)
PY
