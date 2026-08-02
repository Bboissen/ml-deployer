#!/usr/bin/env python3
"""Read-only AWS account prerequisite audit with redacted, mode-0600 output."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

EXPECTED_REGION = "us-east-1"
CPU_PARAMETER = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
GPU_PARAMETER = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id"
CPU_OWNER = "099720109477"
QUOTA_NEEDLES = ("Running On-Demand Standard", "Running On-Demand G and VT", "All Standard Spot", "All G and VT Spot", "Elastic IP")
CANDIDATE_TYPES = ("t3.small", "c7i-flex.large", "m7i-flex.large", "r7i.large", "r7i.4xlarge", "g6e.xlarge", "g6e.8xlarge")


@dataclass(frozen=True)
class Check:
    name: str
    status: str
    detail: str


class Audit:
    def __init__(self) -> None:
        self.checks: list[Check] = []

    def add(self, name: str, status: str, detail: str) -> None:
        self.checks.append(Check(name, status, detail))

    @property
    def failed(self) -> bool:
        return any(item.status in {"FAIL", "MANUAL_EVIDENCE_REQUIRED"} for item in self.checks)


def run_aws(profile: str, region: str, *args: str) -> Any:
    command = ["aws", *args, "--profile", profile, "--region", region, "--output", "json", "--no-cli-pager"]
    completed = subprocess.run(command, check=False, capture_output=True, text=True, timeout=45)
    if completed.returncode:
        message = completed.stderr.strip().splitlines()[-1] if completed.stderr.strip() else "AWS CLI command failed"
        raise RuntimeError(message[:300])
    return json.loads(completed.stdout or "null")


def ensure_tools(audit: Audit) -> None:
    for command in ("aws", "tofu"):
        if shutil.which(command) is None:
            audit.add(f"tool_{command}", "FAIL", f"{command} is required")
            continue
        completed = subprocess.run([command, "--version"], check=False, capture_output=True, text=True)
        version = (completed.stdout or completed.stderr).strip().splitlines()[0] if completed.returncode == 0 else "missing"
        if completed.returncode:
            audit.add(f"tool_{command}", "FAIL", f"{command} is required")
        elif command == "aws" and not version.startswith("aws-cli/2."):
            audit.add("tool_aws", "FAIL", "AWS CLI v2 is required")
        else:
            audit.add(f"tool_{command}", "PASS", version[:160])


def clock_status() -> tuple[str, str]:
    if Path("/run/systemd/timesync/synchronized").exists():
        return "PASS", "systemd synchronization marker present"
    completed = subprocess.run(
        ["timedatectl", "show", "-p", "NTPSynchronized", "--value"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0 and completed.stdout.strip().lower() == "yes":
        return "PASS", "NTP synchronized"
    return "WARN", "clock synchronization could not be confirmed"


def assert_no_static_credentials(audit: Audit) -> None:
    names = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")
    populated = [name for name in names if os.environ.get(name)]
    if populated:
        audit.add("credential_source", "FAIL", "static/provider-chain AWS credential variables are set; use AWS CLI aws login")
    else:
        audit.add("credential_source", "PASS", "no static AWS credential variables are set")


def count_resources(profile: str, region: str, audit: Audit) -> dict[str, int | None]:
    calls: dict[str, tuple[str, ...]] = {
        "ec2_instances": ("ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=pending,running,stopping,stopped"),
        "ebs_volumes": ("ec2", "describe-volumes"),
        "elastic_ips": ("ec2", "describe-addresses"),
        "nat_gateways": ("ec2", "describe-nat-gateways", "--filter", "Name=state,Values=pending,available"),
        "launch_templates": ("ec2", "describe-launch-templates"),
        "auto_scaling_groups": ("autoscaling", "describe-auto-scaling-groups"),
        "load_balancers_v2": ("elbv2", "describe-load-balancers"),
        "rds_instances": ("rds", "describe-db-instances"),
        "eks_clusters": ("eks", "list-clusters"),
        "s3_buckets": ("s3api", "list-buckets"),
    }
    keys = {
        "ec2_instances": ("Reservations", "Instances"),
        "ebs_volumes": ("Volumes",),
        "elastic_ips": ("Addresses",),
        "nat_gateways": ("NatGateways",),
        "launch_templates": ("LaunchTemplates",),
        "auto_scaling_groups": ("AutoScalingGroups",),
        "load_balancers_v2": ("LoadBalancers",),
        "rds_instances": ("DBInstances",),
        "eks_clusters": ("clusters",),
        "s3_buckets": ("Buckets",),
    }
    result: dict[str, int | None] = {}
    for name, command in calls.items():
        try:
            payload = run_aws(profile, region, *command)
            if name == "ec2_instances":
                value = sum(len(item.get("Instances", [])) for item in payload.get("Reservations", []))
            else:
                value: Any = payload
                for key in keys[name]:
                    value = value.get(key, [])
                value = len(value)
            result[name] = value
            audit.add(f"inventory_{name}", "PASS" if value == 0 else "WARN", f"count={value}")
        except RuntimeError as exc:
            result[name] = None
            audit.add(f"inventory_{name}", "WARN", f"not readable: {exc}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    audit = Audit()
    ensure_tools(audit)
    assert_no_static_credentials(audit)
    clock_state, clock_detail = clock_status()
    audit.add("clock", clock_state, clock_detail)

    profile = os.environ.get("AWS_PROFILE", "")
    region = os.environ.get("AWS_REGION", "")
    expected_account = os.environ.get("AWS_ACCOUNT_ID", "")
    if not profile:
        audit.add("profile", "FAIL", "AWS_PROFILE is required")
    else:
        audit.add("profile", "PASS", profile)
    if region != EXPECTED_REGION:
        audit.add("region", "FAIL", f"AWS_REGION must be {EXPECTED_REGION}")
    else:
        audit.add("region", "PASS", region)
    if not re.fullmatch(r"\d{12}", expected_account):
        audit.add("expected_account", "FAIL", "AWS_ACCOUNT_ID must be an exact 12-digit account ID")

    details: dict[str, Any] = {
        "availability_zones": [],
        "quotas": [],
        "instance_types": [],
        "instance_offerings": [],
        "images": [],
        "inventory": {},
    }
    prerequisites_ok = profile and region == EXPECTED_REGION and re.fullmatch(r"\d{12}", expected_account)
    if prerequisites_ok and not any(item.name == "tool_aws" and item.status == "FAIL" for item in audit.checks):
        try:
            caller = run_aws(profile, region, "sts", "get-caller-identity")
            actual_account = str(caller.get("Account", ""))
            caller_arn = str(caller.get("Arn", ""))
            audit.add("login_identity", "PASS" if actual_account == expected_account else "FAIL", f"account={actual_account} caller={caller_arn}")
        except RuntimeError as exc:
            audit.add("login_identity", "FAIL", f"aws login session unavailable: {exc}")
            caller = {}

        try:
            regions = run_aws(
                profile,
                region,
                "account",
                "list-regions",
                "--region-opt-status-contains",
                "ENABLED_BY_DEFAULT",
                "ENABLED",
            )
            target = next((item for item in regions.get("Regions", []) if item.get("RegionName") == region), None)
            audit.add("region_enabled", "PASS" if target else "FAIL", f"status={target.get('RegionOptStatus') if target else 'not-enabled'}")
        except RuntimeError as exc:
            audit.add("region_enabled", "FAIL", str(exc))

        try:
            zones = run_aws(profile, region, "ec2", "describe-availability-zones", "--filters", "Name=state,Values=available")
            details["availability_zones"] = [
                {"name": item.get("ZoneName"), "id": item.get("ZoneId"), "state": item.get("State")}
                for item in zones.get("AvailabilityZones", [])
            ]
            audit.add("availability_zones", "PASS" if details["availability_zones"] else "FAIL", f"available={len(details['availability_zones'])}")
        except RuntimeError as exc:
            audit.add("availability_zones", "FAIL", str(exc))

        try:
            block = run_aws(profile, region, "s3control", "get-public-access-block", "--account-id", expected_account)
            config = block.get("PublicAccessBlockConfiguration", {})
            enabled = all(config.get(key) is True for key in ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets"))
            audit.add("s3_account_public_access_block", "PASS" if enabled else "FAIL", "all four controls enabled" if enabled else "one or more controls disabled")
        except RuntimeError as exc:
            audit.add("s3_account_public_access_block", "FAIL", str(exc))

        try:
            encryption = run_aws(profile, region, "ec2", "get-ebs-encryption-by-default")
            enabled = encryption.get("EbsEncryptionByDefault") is True
            audit.add("ebs_encryption_by_default", "PASS" if enabled else "FAIL", f"enabled={enabled}")
        except RuntimeError as exc:
            audit.add("ebs_encryption_by_default", "FAIL", str(exc))

        for family, parameter in (("cpu", CPU_PARAMETER), ("gpu", GPU_PARAMETER)):
            try:
                resolved = run_aws(profile, region, "ssm", "get-parameter", "--name", parameter)
                image_id = resolved.get("Parameter", {}).get("Value", "")
                images = run_aws(profile, region, "ec2", "describe-images", "--image-ids", image_id).get("Images", [])
                image = images[0] if len(images) == 1 else {}
                owner_ok = image.get("OwnerId") == CPU_OWNER if family == "cpu" else image.get("ImageOwnerAlias") == "amazon"
                name = str(image.get("Name", "")).lower()
                family_ok = "ubuntu" in name and (family == "cpu" or "nvidia" in name)
                valid = owner_ok and family_ok and image.get("Architecture") == "x86_64" and image.get("State") == "available"
                details["images"].append({
                    "family": family,
                    "parameter": parameter,
                    "image_id": image_id,
                    "name": image.get("Name"),
                    "owner_id": image.get("OwnerId"),
                    "owner_alias": image.get("ImageOwnerAlias"),
                    "architecture": image.get("Architecture"),
                    "creation_date": image.get("CreationDate"),
                    "resolved_at": datetime.now(UTC).isoformat(),
                })
                audit.add(f"{family}_ami", "PASS" if valid else "FAIL", f"image={image_id} owner_ok={owner_ok} architecture={image.get('Architecture')}")
            except RuntimeError as exc:
                audit.add(f"{family}_ami", "FAIL", str(exc))

        try:
            instance_types = run_aws(
                profile,
                region,
                "ec2",
                "describe-instance-types",
                "--instance-types",
                *CANDIDATE_TYPES,
            ).get("InstanceTypes", [])
            details["instance_types"] = [
                {
                    "type": item.get("InstanceType"),
                    "architectures": item.get("ProcessorInfo", {}).get("SupportedArchitectures", []),
                    "vcpu": item.get("VCpuInfo", {}).get("DefaultVCpus"),
                    "memory_mib": item.get("MemoryInfo", {}).get("SizeInMiB"),
                    "ebs_optimized": item.get("EbsInfo", {}).get("EbsOptimizedSupport"),
                    "network_performance": item.get("NetworkInfo", {}).get("NetworkPerformance"),
                    "instance_storage_supported": item.get("InstanceStorageSupported"),
                    "usage_classes": item.get("SupportedUsageClasses", []),
                    "current_generation": item.get("CurrentGeneration"),
                }
                for item in instance_types
            ]
            returned = {item["type"] for item in details["instance_types"]}
            missing = sorted(set(CANDIDATE_TYPES) - returned)
            audit.add("candidate_instance_types", "PASS" if not missing else "WARN", f"resolved={len(returned)} missing={','.join(missing)}")
        except RuntimeError as exc:
            audit.add("candidate_instance_types", "WARN", str(exc))

        try:
            offerings = run_aws(
                profile,
                region,
                "ec2",
                "describe-instance-type-offerings",
                "--location-type",
                "availability-zone",
                "--filters",
                f"Name=instance-type,Values={','.join(CANDIDATE_TYPES)}",
            ).get("InstanceTypeOfferings", [])
            details["instance_offerings"] = [
                {"type": item.get("InstanceType"), "availability_zone": item.get("Location")} for item in offerings
            ]
            audit.add("candidate_instance_offerings", "PASS" if offerings else "WARN", f"offerings={len(offerings)}")
        except RuntimeError as exc:
            audit.add("candidate_instance_offerings", "WARN", str(exc))

        try:
            quotas = run_aws(profile, region, "service-quotas", "list-service-quotas", "--service-code", "ec2")
            details["quotas"] = [
                {"name": item.get("QuotaName"), "value": item.get("Value"), "code": item.get("QuotaCode"), "adjustable": item.get("Adjustable")}
                for item in quotas.get("Quotas", [])
                if any(needle in str(item.get("QuotaName", "")) for needle in QUOTA_NEEDLES)
            ]
            audit.add("ec2_quotas", "PASS" if details["quotas"] else "WARN", f"matched={len(details['quotas'])}")
        except RuntimeError as exc:
            audit.add("ec2_quotas", "WARN", str(exc))

        today = datetime.now(UTC).date()
        start = today.replace(day=1).isoformat()
        end = (today + timedelta(days=1)).isoformat()
        try:
            run_aws(profile, region, "ce", "get-cost-and-usage", "--time-period", f"Start={start},End={end}", "--granularity", "MONTHLY", "--metrics", "UnblendedCost")
            audit.add("billing_read", "PASS", "bounded Cost Explorer query succeeded")
        except RuntimeError as exc:
            audit.add("billing_read", "FAIL", str(exc))

        budget_value = os.environ.get("AWS_MONTHLY_BUDGET_USD", "")
        try:
            budgets = run_aws(profile, region, "budgets", "describe-budgets", "--account-id", expected_account).get("Budgets", [])
            selected = next((item for item in budgets if item.get("BudgetName") == "spotify-predictor-monthly"), None)
            amount_matches = selected is not None and float(selected.get("BudgetLimit", {}).get("Amount", -1)) == float(budget_value)
            valid = amount_matches and selected.get("BudgetType") == "COST" and selected.get("TimeUnit") == "MONTHLY"
            audit.add("monthly_budget", "PASS" if valid else "FAIL", "named monthly cost budget matches explicit amount" if valid else "budget missing or does not match explicit amount")
        except (RuntimeError, ValueError) as exc:
            audit.add("monthly_budget", "FAIL", str(exc))

        anomaly_value = os.environ.get("AWS_ANOMALY_THRESHOLD_USD", "")
        try:
            monitors = run_aws(profile, region, "ce", "get-anomaly-monitors").get("AnomalyMonitors", [])
            subscriptions = run_aws(profile, region, "ce", "get-anomaly-subscriptions").get("AnomalySubscriptions", [])
            threshold_matches = any(float(item.get("Threshold", -1)) == float(anomaly_value) for item in subscriptions)
            valid = bool(monitors) and bool(subscriptions) and threshold_matches
            audit.add("cost_anomaly_detection", "PASS" if valid else "FAIL", "monitor and matching subscription found" if valid else "monitor/subscription missing or threshold mismatch")
        except (RuntimeError, ValueError) as exc:
            audit.add("cost_anomaly_detection", "FAIL", str(exc))

        try:
            run_aws(profile, region, "ssm", "describe-instance-information", "--max-results", "5")
            audit.add("session_manager_read", "PASS", "Systems Manager inventory read succeeded")
        except RuntimeError as exc:
            audit.add("session_manager_read", "WARN", str(exc))

        details["inventory"] = count_resources(profile, region, audit)

    budget = os.environ.get("AWS_MONTHLY_BUDGET_USD", "")
    anomaly = os.environ.get("AWS_ANOMALY_THRESHOLD_USD", "")
    for name, value in (("monthly_budget_setting", budget), ("anomaly_threshold_setting", anomaly)):
        try:
            valid = float(value) > 0
        except ValueError:
            valid = False
        audit.add(name, "PASS" if valid else "FAIL", "explicit positive USD value set" if valid else "explicit positive USD value required")

    manual = os.environ.get("AWS_MANUAL_ACCOUNT_EVIDENCE_CONFIRMED", "").lower() == "true"
    audit.add(
        "manual_console_evidence",
        "PASS" if manual else "MANUAL_EVIDENCE_REQUIRED",
        "operator assertion recorded" if manual else "complete docs/account-setup-aws.md and set AWS_MANUAL_ACCOUNT_EVIDENCE_CONFIRMED=true",
    )

    payload = {
        "schema_version": 1,
        "checked_at": datetime.now(UTC).isoformat(),
        "profile": profile,
        "expected_account_id": expected_account,
        "region": region,
        "checks": [asdict(item) for item in audit.checks],
        **details,
        "overall_status": "FAIL" if audit.failed else "PASS",
    }
    rendered = json.dumps(payload, sort_keys=True, indent=2) + "\n"
    if args.json or args.output:
        output = args.output or Path("artifacts/audits") / f"aws-account-{datetime.now(UTC):%Y%m%dT%H%M%SZ}.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        old_umask = os.umask(0o077)
        try:
            fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(rendered)
        finally:
            os.umask(old_umask)
        print(rendered, end="")
    else:
        for item in audit.checks:
            print(f"{item.status} {item.name}: {item.detail}")
        print(f"overall_status={payload['overall_status']}")
    return 1 if audit.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
