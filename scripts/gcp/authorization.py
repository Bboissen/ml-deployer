#!/usr/bin/env python3
"""Issue and consume exact-plan, one-use GCP apply authorizations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import stat
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from plan_policy import PolicyError
from plan_policy import validate as validate_plan

PROJECT = "example-project"
STATE_BUCKET = f"{PROJECT}-tofu-state"
ALLOWED_ROOTS = {"tofu/gcp/bootstrap", "tofu/gcp/storage", "tofu/gcp/network", "tofu/gcp/training-node"}
OPERATIONS = {
    "tofu/gcp/bootstrap": "bootstrap",
    "tofu/gcp/storage": "storage",
    "tofu/gcp/network": "network",
    "tofu/gcp/training-node": "compute",
}


class AuthorizationError(ValueError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def change_counts(plan_json: dict[str, Any]) -> dict[str, int]:
    counts = {"add": 0, "change": 0, "destroy": 0}
    for resource in plan_json.get("resource_changes", []):
        actions = resource.get("change", {}).get("actions", [])
        counts["add"] += int("create" in actions)
        counts["change"] += int("update" in actions)
        counts["destroy"] += int("delete" in actions)
    return counts


def render_plan(tofu: str, root: str, plan: Path) -> dict[str, Any]:
    rendered = subprocess.run(
        [tofu, f"-chdir={root}", "show", "-json", str(plan.resolve())],
        check=True,
        capture_output=True,
        text=True,
    )
    value = json.loads(rendered.stdout)
    if not isinstance(value, dict):
        raise AuthorizationError("saved plan JSON is invalid")
    return value


def validate(
    receipt: dict[str, Any],
    *,
    root: str,
    profile: str,
    plan: Path,
    now: int | None = None,
    expected_counts: dict[str, int] | None = None,
    billing_account_id: str | None = None,
) -> None:
    now = int(time.time()) if now is None else now
    if root not in ALLOWED_ROOTS or receipt.get("root") != root:
        raise AuthorizationError("authorization root binding failed")
    if receipt.get("project_id") != PROJECT:
        raise AuthorizationError("authorization project binding failed")
    if receipt.get("profile") != profile:
        raise AuthorizationError("authorization profile binding failed")
    if receipt.get("plan_sha256") != sha256(plan):
        raise AuthorizationError("authorization plan hash binding failed")
    if not isinstance(receipt.get("issued_at"), int) or not isinstance(receipt.get("expires_at"), int):
        raise AuthorizationError("authorization timestamps are invalid")
    if receipt["issued_at"] >= receipt["expires_at"] or now >= receipt["expires_at"]:
        raise AuthorizationError("authorization is expired")
    counts = receipt.get("expected_changes")
    if not isinstance(counts, dict) or set(counts) != {"add", "change", "destroy"} or any(type(value) is not int or value < 0 for value in counts.values()):
        raise AuthorizationError("authorization change counts are invalid")
    if counts.get("destroy") != 0:
        raise AuthorizationError("authorization permits destroy actions")
    if expected_counts is not None and counts != expected_counts:
        raise AuthorizationError("authorization change counts do not match the saved plan")
    if billing_account_id is not None and receipt.get("billing_account_id") != billing_account_id:
        raise AuthorizationError("authorization billing-account binding failed")
    if root == "tofu/gcp/bootstrap" and receipt.get("bucket_name") != STATE_BUCKET:
        raise AuthorizationError("authorization state-bucket binding failed")
    if not receipt.get("authorization_id") or not receipt.get("operator_identity"):
        raise AuthorizationError("authorization identity fields are missing")
    if not isinstance(receipt.get("max_estimated_cost"), (int, float)) or receipt["max_estimated_cost"] < 0:
        raise AuthorizationError("authorization cost bound is invalid")
    if not receipt.get("one_use_nonce"):
        raise AuthorizationError("authorization nonce is missing")


def issue(args: argparse.Namespace) -> int:
    if args.root not in ALLOWED_ROOTS:
        raise AuthorizationError("root is not allowlisted")
    if not args.plan.is_file():
        raise AuthorizationError("exact saved plan is required")
    billing = os.environ.get("GCP_BILLING_ACCOUNT_ID", "")
    operator = os.environ.get("GCP_ADMIN_EMAIL", "")
    if not billing or not operator:
        raise AuthorizationError("GCP_BILLING_ACCOUNT_ID and GCP_ADMIN_EMAIL are required")
    tofu = os.environ.get("TOFU", "tofu")
    plan_json = render_plan(tofu, args.root, args.plan)
    validate_plan(plan_json, OPERATIONS[args.root])
    counts = change_counts(plan_json)
    if counts["destroy"]:
        raise AuthorizationError("plans containing destroy cannot be authorized")
    now = int(time.time())
    receipt = {
        "authorization_id": str(uuid.uuid4()),
        "project_id": PROJECT,
        "root": args.root,
        "profile": args.profile,
        "billing_account_id": billing,
        "bucket_name": STATE_BUCKET if args.root.endswith("bootstrap") else "",
        "plan_sha256": sha256(args.plan),
        "expected_changes": counts,
        "max_estimated_cost": float(os.environ.get("GCP_MAX_AUTHORIZED_COST", "0")),
        "issued_at": now,
        "expires_at": now + args.ttl_minutes * 60,
        "operator_identity": operator,
        "one_use_nonce": secrets.token_hex(16),
    }
    output = args.output or Path(".gcp-runtime/authorizations") / f"{receipt['authorization_id']}.json"
    private_write(output, receipt)
    print(output)
    return 0


def apply(args: argparse.Namespace) -> int:
    if stat.S_IMODE(args.authorization.stat().st_mode) != 0o600:
        raise AuthorizationError("authorization file mode must be 0600")
    receipt = json.loads(args.authorization.read_text())
    tofu = os.environ.get("TOFU", "tofu")
    plan_json = render_plan(tofu, args.root, args.plan)
    validate_plan(plan_json, OPERATIONS[args.root])
    billing = os.environ.get("GCP_BILLING_ACCOUNT_ID", "")
    if not billing:
        raise AuthorizationError("GCP_BILLING_ACCOUNT_ID is required")
    validate(
        receipt,
        root=args.root,
        profile=args.profile,
        plan=args.plan,
        expected_counts=change_counts(plan_json),
        billing_account_id=billing,
    )
    ledger = Path(".gcp-runtime/authorization-ledger")
    marker = ledger / f"{receipt['authorization_id']}.consumed.json"
    private_write(marker, {"authorization_id": receipt["authorization_id"], "consumed_at": int(time.time()), "plan_sha256": sha256(args.plan)})
    print(
        f"project={PROJECT} root={args.root} region=us-central1 zone=us-central1-a "
        f"profile={args.profile} plan_sha256={receipt['plan_sha256']} authorization_id={receipt['authorization_id']} "
        f"expires_at={receipt['expires_at']} changes={receipt['expected_changes']}"
    )
    completed = subprocess.run([tofu, f"-chdir={args.root}", "apply", str(args.plan.resolve())], check=False)
    public_receipt = {
        "authorization_id": receipt["authorization_id"],
        "project_id": PROJECT,
        "root": args.root,
        "profile": args.profile,
        "plan_sha256": receipt["plan_sha256"],
        "finished_at": int(time.time()),
        "exit_code": completed.returncode,
    }
    out = Path("artifacts/receipts") / f"gcp-apply-{receipt['authorization_id']}.json"
    out.write_text(json.dumps(public_receipt, sort_keys=True, indent=2) + "\n")
    return completed.returncode


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    issue_cmd = commands.add_parser("issue")
    issue_cmd.add_argument("--root", required=True)
    issue_cmd.add_argument("--profile", required=True)
    issue_cmd.add_argument("--plan", required=True, type=Path)
    issue_cmd.add_argument("--output", type=Path)
    issue_cmd.add_argument("--ttl-minutes", type=int, default=30)
    issue_cmd.set_defaults(run=issue)
    apply_cmd = commands.add_parser("apply")
    apply_cmd.add_argument("--root", required=True)
    apply_cmd.add_argument("--profile", required=True)
    apply_cmd.add_argument("--plan", required=True, type=Path)
    apply_cmd.add_argument("--authorization", required=True, type=Path)
    apply_cmd.set_defaults(run=apply)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.run(args)
    except (OSError, json.JSONDecodeError, AuthorizationError, PolicyError, subprocess.CalledProcessError, ValueError) as exc:
        print(f"gcp-authorization: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
