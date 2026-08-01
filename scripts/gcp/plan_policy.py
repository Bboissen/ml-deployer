#!/usr/bin/env python3
"""Fail-closed policy checks for GCP OpenTofu plan JSON."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

PROJECT = "example-project"
REGION = "us-central1"
ALLOWED_MACHINES = {"e2-micro", "e2-standard-2", "e2-highmem-4"}
PUBLIC_MEMBERS = {"allUsers", "allAuthenticatedUsers"}
FORBIDDEN_TYPES = {
    "google_service_account_key",
    "google_compute_address",
    "google_compute_disk",
    "google_compute_router_nat",
    "google_compute_forwarding_rule",
    "google_container_cluster",
    "google_project_service",
    "google_sql_database_instance",
    "google_storage_bucket_access_control",
    "google_storage_bucket_acl",
    "google_storage_bucket_iam_policy",
    "google_storage_default_object_access_control",
    "google_storage_default_object_acl",
}
PERSISTENT_TYPES = {"google_storage_bucket", "google_compute_network", "google_compute_subnetwork"}
STORAGE_BUCKETS = {
    "bronze": f"{PROJECT}-bronze",
    "silver": f"{PROJECT}-silver",
    "artifacts": f"{PROJECT}-artifacts",
}
REQUIRED_LABELS = {"project", "owner", "environment", "managed_by", "layer"}
STORAGE_IAM = {
    "google_storage_bucket_iam_member.publisher_bronze_create": ("bronze", "data-publisher@", "roles/storage.objectCreator"),
    "google_storage_bucket_iam_member.publisher_bronze_read": ("bronze", "data-publisher@", "roles/storage.objectViewer"),
    "google_storage_bucket_iam_member.publisher_silver_create": ("silver", "data-publisher@", "roles/storage.objectCreator"),
    "google_storage_bucket_iam_member.publisher_silver_read": ("silver", "data-publisher@", "roles/storage.objectViewer"),
    "google_storage_bucket_iam_member.trainer_bronze_read": ("bronze", "training-runtime@", "roles/storage.objectViewer"),
    "google_storage_bucket_iam_member.trainer_silver_read": ("silver", "training-runtime@", "roles/storage.objectViewer"),
    "google_storage_bucket_iam_member.trainer_artifact_create": ("artifacts", "training-runtime@", "roles/storage.objectCreator"),
}
LEGACY_STORAGE_ROLES = {
    "roles/storage.legacyBucketOwner",
    "roles/storage.legacyBucketReader",
    "roles/storage.legacyObjectOwner",
    "roles/storage.legacyObjectReader",
}


class PolicyError(ValueError):
    pass


def _changes(plan: dict[str, Any]) -> list[dict[str, Any]]:
    value = plan.get("resource_changes", [])
    if not isinstance(value, list):
        raise PolicyError("resource_changes must be a list")
    return value


def validate(plan: dict[str, Any], operation: str) -> None:
    changes = _changes(plan)
    instances = [item for item in changes if item.get("type") == "google_compute_instance"]
    if len(instances) > 1:
        raise PolicyError("at most one VM is allowed")

    for item in changes:
        resource_type = item.get("type", "")
        address = item.get("address", "unknown")
        change = item.get("change", {})
        after = change.get("after") or {}
        actions = change.get("actions") or []

        if resource_type in FORBIDDEN_TYPES:
            raise PolicyError(f"forbidden resource type: {resource_type}")
        if operation == "compute" and resource_type in PERSISTENT_TYPES and "delete" in actions:
            raise PolicyError(f"compute operation deletes persistent resource: {address}")

        project = after.get("project")
        if project is not None and project != PROJECT:
            raise PolicyError(f"wrong project on {address}")
        region = after.get("region")
        if region is not None and region != REGION:
            raise PolicyError(f"wrong region on {address}")

        if resource_type == "google_storage_bucket":
            if str(after.get("location", "")).lower() != REGION:
                raise PolicyError(f"bucket outside {REGION}: {address}")
            if after.get("storage_class") != "STANDARD":
                raise PolicyError(f"bucket is not Standard: {address}")
            if after.get("force_destroy") is not False:
                raise PolicyError(f"bucket force_destroy must be false: {address}")
            if after.get("public_access_prevention") != "enforced":
                raise PolicyError(f"bucket public access prevention missing: {address}")
            if after.get("uniform_bucket_level_access") is not True:
                raise PolicyError(f"bucket UBLA must be enabled: {address}")
            if after.get("autoclass"):
                raise PolicyError(f"bucket Autoclass is forbidden: {address}")
            if after.get("cors") or after.get("website"):
                raise PolicyError(f"bucket CORS and website hosting must be disabled: {address}")
            if after.get("requester_pays") is True:
                raise PolicyError(f"bucket requester pays must be disabled: {address}")
            if after.get("encryption"):
                raise PolicyError(f"customer-managed bucket encryption is outside V0: {address}")
            if after.get("retention_policy"):
                raise PolicyError(f"retention lock is forbidden in V0: {address}")
            soft_delete = after.get("soft_delete_policy") or []
            if not soft_delete or int(soft_delete[0].get("retention_duration_seconds") or 0) < 604800:
                raise PolicyError(f"bucket soft delete must be at least seven days: {address}")
            if any(layer in address.lower() for layer in ("bronze", "silver")) and after.get("lifecycle_rule"):
                raise PolicyError(f"unexpected lifecycle deletion on accepted data: {address}")
            if operation == "storage":
                layers = [layer for layer in STORAGE_BUCKETS if f"module.{layer}." in address]
                if len(layers) != 1:
                    raise PolicyError(f"unexpected storage bucket address: {address}")
                layer = layers[0]
                if after.get("name") != STORAGE_BUCKETS[layer]:
                    raise PolicyError(f"wrong {layer} bucket name")
                labels = after.get("labels") or {}
                if not REQUIRED_LABELS.issubset(labels) or labels.get("layer") != layer:
                    raise PolicyError(f"required {layer} bucket labels are missing")
                versioning = after.get("versioning") or []
                enabled = bool(versioning and versioning[0].get("enabled"))
                if layer == "bronze" and not enabled:
                    raise PolicyError("Bronze bucket versioning must be enabled")
                if layer == "artifacts" and enabled:
                    raise PolicyError("artifact bucket versioning must be disabled in V0")
                lifecycle_rules = after.get("lifecycle_rule") or []
                if layer == "artifacts" and not lifecycle_rules:
                    raise PolicyError("artifact temporary lifecycle rule is missing")
                for rule in lifecycle_rules:
                    condition = (rule.get("condition") or [{}])[0]
                    prefixes = condition.get("matches_prefix") or []
                    if layer == "artifacts":
                        action = (rule.get("action") or [{}])[0]
                        if action.get("type") != "Delete" or int(condition.get("age") or 0) < 7:
                            raise PolicyError("artifact lifecycle must be a bounded age deletion")
                        if set(prefixes) != {"artifacts/tmp/", "artifacts/runs/unaccepted/"}:
                            raise PolicyError("artifact lifecycle prefixes exceed temporary data")
            if operation == "bootstrap":
                versioning = after.get("versioning") or []
                if not versioning or versioning[0].get("enabled") is not True:
                    raise PolicyError("state bucket versioning must be enabled")

        if resource_type in {"google_storage_bucket_iam_member", "google_project_iam_member"}:
            if after.get("member") in PUBLIC_MEMBERS:
                raise PolicyError(f"public IAM member on {address}")
            member = str(after.get("member", ""))
            bucket = str(after.get("bucket", "")).removeprefix("b/")
            role = str(after.get("role", ""))
            if "training-runtime@" in member and any(layer in bucket for layer in ("-bronze", "-silver")) and role != "roles/storage.objectViewer":
                raise PolicyError("training runtime may only read Bronze and Silver")
            if "data-publisher@" in member and "tofu-state" in bucket:
                raise PolicyError("publisher must not access the state bucket")
            if operation == "storage" and resource_type == "google_storage_bucket_iam_member":
                expected = STORAGE_IAM.get(address)
                if expected is None:
                    raise PolicyError(f"unexpected storage bucket IAM member: {address}")
                layer, identity, expected_role = expected
                if bucket != STORAGE_BUCKETS[layer] or identity not in member or role != expected_role:
                    raise PolicyError(f"storage IAM binding does not match its fixed role: {address}")

        if operation == "storage" and resource_type == "google_service_account":
            expected_accounts = {
                "google_service_account.data_publisher": "data-publisher",
                "google_service_account.training_runtime": "training-runtime",
            }
            if expected_accounts.get(address) != after.get("account_id"):
                raise PolicyError(f"unexpected storage service account: {address}")

        if operation == "storage" and resource_type == "google_service_account_iam_member":
            if not address.startswith("google_service_account_iam_member.admin_impersonates_"):
                raise PolicyError(f"unexpected service-account IAM binding: {address}")
            if after.get("role") != "roles/iam.serviceAccountTokenCreator" or not str(after.get("member", "")).startswith("user:"):
                raise PolicyError("storage identities may only be impersonated by a user token creator")

        if resource_type == "google_storage_bucket_iam_binding":
            if operation != "storage":
                raise PolicyError("authoritative bucket IAM bindings are storage-only")
            layers = [layer for layer in STORAGE_BUCKETS if address.startswith(f"google_storage_bucket_iam_binding.{layer}_legacy")]
            if len(layers) != 1:
                raise PolicyError(f"unexpected authoritative bucket IAM binding: {address}")
            bucket = str(after.get("bucket", "")).removeprefix("b/")
            if bucket != STORAGE_BUCKETS[layers[0]] or after.get("role") not in LEGACY_STORAGE_ROLES or after.get("members"):
                raise PolicyError("legacy bucket IAM remediation must be an empty fixed-role binding")

        if resource_type == "google_compute_firewall":
            for source in after.get("source_ranges") or []:
                if source in {"0.0.0.0/0", "::/0"}:
                    raise PolicyError(f"public ingress on {address}")

        if resource_type == "google_compute_instance":
            if after.get("machine_type") not in ALLOWED_MACHINES:
                raise PolicyError("machine type is not allowlisted")
            scheduling = after.get("scheduling") or []
            scheduling = scheduling[0] if scheduling else {}
            duration = after.get("params", {}).get("max_run_duration") or scheduling.get("max_run_duration")
            if not duration:
                raise PolicyError("VM max_run_duration is missing")
            if scheduling.get("instance_termination_action") != "DELETE":
                raise PolicyError("VM termination action must be DELETE")
            if after.get("guest_accelerator") or after.get("scratch_disk"):
                raise PolicyError("GPU and local SSD are forbidden in initial profiles")
            metadata = after.get("metadata") or {}
            flattened = json.dumps(metadata).lower()
            if any(word in flattened for word in ("private_key", "access_token", "secret_access_key", "password=")):
                raise PolicyError("VM metadata resembles a credential")
            for disk in after.get("attached_disk") or []:
                if disk.get("device_name") and disk.get("auto_delete") is not True:
                    raise PolicyError("attached disposable disk must auto-delete")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan", type=Path)
    parser.add_argument("--operation", choices=("bootstrap", "storage", "network", "compute"), required=True)
    args = parser.parse_args()
    try:
        validate(json.loads(args.plan.read_text()), args.operation)
    except (OSError, json.JSONDecodeError, PolicyError) as exc:
        print(f"gcp-plan-policy: {exc}")
        return 1
    print(f"gcp-plan-policy: accepted {args.operation} plan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
