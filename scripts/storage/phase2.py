#!/usr/bin/env python3
"""Explicitly gated controller for the bounded Phase 2 storage/cache smoke."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from spotify_ray_infra.phase2_control import (
    LIVE_ORDER, ProtocolError, consume_authorization, fetch_live_size,
    render_cleanup_bundle, validate_controller_crosscheck,
    validate_live_recheck,
)
from spotify_ray_infra.storage_protocol import (
    FULL_BYTES, FULL_PARTITIONS, MANIFEST_NAME, boto3_bronze_client, build_pack, canonical_json,
    parse_manifest, presign_get_plan, publish_and_verify, write_private_json,
)

ROOT = Path(__file__).resolve().parents[2]
CONTROL = ROOT / "src/spotify_ray_infra/phase2_control.py"
PROTOCOL = ROOT / "src/spotify_ray_infra/storage_protocol.py"
WORKER = ROOT / "scripts/storage/phase2_worker.py"


def _run(command: list[str], timeout: int = 120, json_output: bool = False):
    try:
        result = subprocess.run(command, check=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProtocolError(f"command failed ({Path(command[0]).name}:{type(exc).__name__})") from None
    if len(result.stdout) > 2 * 1024 * 1024:
        raise ProtocolError("command output exceeded bound")
    if not json_output:
        return None
    try:
        return json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("command returned invalid JSON") from exc


def _tf(tf: str, directory: Path, *arguments: str, timeout: int = 120, json_output: bool = False):
    return _run([tf, f"-chdir={directory}", *arguments], timeout, json_output)


def _storage_outputs(tf: str, storage_dir: Path) -> dict[str, object]:
    value = _tf(tf, storage_dir, "output", "-json", json_output=True)
    return {key: item["value"] for key, item in value.items()}


def _do_droplet(token: str, droplet_id: str) -> dict[str, object]:
    request = urllib.request.Request(
        f"https://api.digitalocean.com/v2/droplets/{droplet_id}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read(1024 * 1024 + 1)
    except (OSError, urllib.error.URLError) as exc:
        raise ProtocolError(f"Droplet cross-check failed ({type(exc).__name__})") from None
    if len(raw) > 1024 * 1024:
        raise ProtocolError("Droplet response exceeded bound")
    return json.loads(raw)["droplet"]


def _ssh_base(host: str, user: str) -> list[str]:
    return ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=5", f"{user}@{host}"]


def _wait_worker_ready(host: str, user: str) -> None:
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            _run([*_ssh_base(host, user), "true"], 10)
            break
        except ProtocolError:
            time.sleep(5)
    else:
        raise ProtocolError("bounded SSH readiness failed")
    readiness = (
        "cloud-init status --wait >/dev/null && "
        "test -x /opt/spotify-ray/venv/bin/python && "
        "systemctl is-active --quiet ray-worker.service && "
        "for i in $(seq 1 90); do pgrep -f '[r]aylet' >/dev/null && exit 0; sleep 2; done; exit 1"
    )
    _run([*_ssh_base(host, user), readiness], 600)


def _read_pack(receipt_path: Path, require_full: bool = False) -> tuple[dict[str, object], Path, dict[str, object]]:
    receipt = json.loads(receipt_path.read_bytes())
    root = Path(receipt["pack_root"])
    manifest_raw = (root / MANIFEST_NAME).read_bytes()
    manifest = parse_manifest(manifest_raw, receipt["test_pack_hash"], receipt["manifest_sha256"])
    object_count = len(manifest["objects"])
    object_bytes = sum(int(item["size"]) for item in manifest["objects"])
    if require_full and (object_count != FULL_PARTITIONS or abs(object_bytes - FULL_BYTES) > FULL_BYTES * 0.01):
        raise ProtocolError("live smoke requires the full 512 MiB/16-object pack")
    return receipt, root, manifest


def build_pack_command(args) -> int:
    result = build_pack(args.out, args.profile)
    manifest = result["manifest"]
    receipt = {
        "manifest_sha256": result["manifest_sha256"],
        "object_bytes": sum(item["size"] for item in manifest["objects"]),
        "object_count": len(manifest["objects"]),
        "pack_root": str(args.out.resolve()),
        "profile": args.profile,
        "protocol": "demo-phase2-pack-receipt-v1",
        "test_pack_hash": result["test_pack_hash"],
    }
    write_private_json(args.receipt, receipt)
    print(canonical_json(receipt).decode(), end="")
    return 0


def dry_run_command() -> int:
    phases = list(LIVE_ORDER)
    actions = [
        "consume authorization; tofu workspace new/select/empty",
        "S3 publish; HEAD/list verify",
        "GET /v2/sizes; validate cost",
        "render/install/start/verify cleanup service",
        "tofu apply exactly once",
        "tofu output; GET exact Droplet; bounded SSH readiness",
        "presign; write 0600; scp modules/runner/plan; chmod",
        "worker cold cache",
        "delete local and remote signed plan",
        "worker warm cache with empty environment and no plan",
        "worker network/Ray receipt; scp receipts",
        "tofu destroy; tofu state list empty",
        "systemctl stop; workspace select default/delete",
    ]
    proof = {
        "apply_count": actions.count("tofu apply exactly once"),
        "commands": [{"phase": phase, "command": action} for phase, action in zip(phases, actions, strict=True)],
        "destroy_before_disarm": phases.index("destroy_and_verify_zero_resources") < phases.index("disarm_and_remove_workspace"),
        "ordered_phases": phases,
        "plan_deleted_before_warm": phases.index("delete_local_and_remote_plan") < phases.index("warm_verify_zero_network"),
    }
    print(canonical_json(proof).decode(), end="")
    return 0


def live_smoke(args) -> int:
    if args.execute_live != "--execute-live":
        raise ProtocolError("exact --execute-live confirmation is required")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,62}", args.run_id):
        raise ProtocolError("run ID is invalid")
    if args.authorization.stat().st_mode & 0o777 != 0o600:
        raise ProtocolError("authorization must have mode 0600")
    tf_name = os.environ.get("TF", "tofu")
    tf = shutil.which(tf_name)
    if not tf:
        raise ProtocolError("Terraform/OpenTofu executable was not found")
    storage = _storage_outputs(tf, args.storage_dir)
    pack_receipt, pack_root, manifest = _read_pack(args.pack_receipt, require_full=True)
    verification_receipt, verification_root, verification_manifest = _read_pack(
        args.verification_pack_receipt, require_full=True
    )
    if pack_root.resolve() == verification_root.resolve() or (
        pack_receipt["test_pack_hash"] != verification_receipt["test_pack_hash"]
        or pack_receipt["manifest_sha256"] != verification_receipt["manifest_sha256"]
        or canonical_json(manifest) != canonical_json(verification_manifest)
    ):
        raise ProtocolError("two distinct full pack builds must match exactly")
    if args.cache_root != "/data/demo-cache":
        raise ProtocolError("live smoke cache root must be /data/demo-cache")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", args.ssh_user):
        raise ProtocolError("SSH user is invalid")
    runtime = args.runtime_dir / args.run_id
    runtime.mkdir(parents=True, mode=0o700)
    controller_receipt = runtime / "controller-terminal.json"
    ledger = args.runtime_dir / "authorization-ledger"
    workspace = f"smoke-{args.run_id}"
    cluster = f"ray-{args.run_id}"
    phases: list[dict[str, object]] = []
    armed = False
    unit_name = f"ray-storage-smoke-cleanup-{args.run_id}.service"
    worker_receipts = [runtime / "cache-cold.json", runtime / "cache-warm.json", runtime / "worker-network.json"]

    def mark(name: str) -> None:
        phases.append({"name": name, "finished_at": int(time.time())})

    try:
        consume_authorization(args.authorization, ledger, args.run_id)
        listed = subprocess.run(
            [tf, f"-chdir={args.worker_dir}", "workspace", "list", "-no-color"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout
        if workspace in {line.strip().lstrip("* ") for line in listed.splitlines()}:
            raise ProtocolError("smoke workspace already exists")
        _tf(tf, args.worker_dir, "workspace", "new", workspace)
        selected = subprocess.run(
            [tf, f"-chdir={args.worker_dir}", "workspace", "show"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        state = subprocess.run(
            [tf, f"-chdir={args.worker_dir}", "state", "list"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        if selected != workspace or state:
            raise ProtocolError("fresh workspace proof failed")
        mark(LIVE_ORDER[0])

        bronze = boto3_bronze_client()
        bucket = str(storage["bronze_bucket_name"])
        publish_and_verify(bronze, bucket, pack_root, pack_receipt["test_pack_hash"], pack_receipt["manifest_sha256"])
        mark(LIVE_ORDER[1])

        token = os.environ.get("DIGITALOCEAN_TOKEN", "")
        size, _ = fetch_live_size(token)
        authorization = json.loads(args.authorization.read_bytes())
        validate_live_recheck(authorization, size)
        mark(LIVE_ORDER[2])

        cleanup_script, cleanup_unit = render_cleanup_bundle(
            runtime / "cleanup", args.run_id, workspace, args.worker_dir, int(time.time()) + 1200, tf
        )
        linger = subprocess.run(
            ["loginctl", "show-user", os.environ.get("USER", ""), "-p", "Linger", "--value"],
            check=True, capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        if linger != "yes":
            raise ProtocolError("systemd user lingering is not enabled")
        user_units = Path.home() / ".config/systemd/user"
        user_units.mkdir(parents=True, exist_ok=True)
        installed_unit = user_units / unit_name
        shutil.copy2(cleanup_unit, installed_unit)
        _run(["systemctl", "--user", "daemon-reload"])
        _run(["systemctl", "--user", "start", "--no-block", unit_name])
        status = subprocess.run(["systemctl", "--user", "is-active", unit_name], capture_output=True, text=True).stdout.strip()
        if status not in {"active", "activating"}:
            raise ProtocolError("cleanup service is not active")
        armed = True
        mark(LIVE_ORDER[3])

        _tf(
            tf, args.worker_dir, "apply", "-auto-approve", "-input=false",
            "-var=worker_count=1", "-var=size=s-1vcpu-1gb", f"-var=cluster_name={cluster}",
            f"-var=vpc_uuid={storage['vpc_uuid']}", f"-var=vpc_name={storage['vpc_name']}", timeout=600,
        )
        mark(LIVE_ORDER[4])
        outputs = _tf(tf, args.worker_dir, "output", "-json", json_output=True)
        values = {key: item["value"] for key, item in outputs.items()}
        droplet_id = str(values["worker_droplet_ids"][0])
        public_ip = str(values["worker_public_ips"][0])
        droplet = _do_droplet(token, droplet_id)
        validate_controller_crosscheck(
            {"selected_vpc_uuid": values["selected_vpc_uuid"], "droplet_ids": values["worker_droplet_ids"]},
            {"vpc_uuid": droplet["vpc_uuid"], "droplet_ids": [droplet["id"]]}, str(storage["vpc_uuid"]),
        )
        _wait_worker_ready(public_ip, args.ssh_user)
        mark(LIVE_ORDER[5])

        plan = presign_get_plan(bronze, bucket, manifest, pack_receipt["manifest_sha256"], 300)
        local_plan = runtime / "signed-plan.json"
        write_private_json(local_plan, plan)
        remote = f"{args.ssh_user}@{public_ip}"
        remote_root = f"/tmp/ray-phase2-{args.run_id}"
        _run([*_ssh_base(public_ip, args.ssh_user), f"mkdir -p {remote_root}/spotify_ray_infra && chmod 700 {remote_root}"])
        _run(["scp", "-q", str(PROTOCOL), str(CONTROL), f"{remote}:{remote_root}/spotify_ray_infra/"])
        _run(["scp", "-q", str(WORKER), f"{remote}:{remote_root}/phase2_worker.py"])
        _run(["scp", "-q", str(local_plan), f"{remote}:{remote_root}/signed-plan.json"])
        _run([*_ssh_base(public_ip, args.ssh_user), f"chmod 600 {remote_root}/signed-plan.json && chmod 700 {remote_root}/phase2_worker.py"])
        mark(LIVE_ORDER[6])

        common = f"--cache-root {args.cache_root} --pack-hash {pack_receipt['test_pack_hash']} --manifest-hash {pack_receipt['manifest_sha256']} --run-id {args.run_id}"
        remote_python = "/opt/spotify-ray/venv/bin/python"
        _run([*_ssh_base(public_ip, args.ssh_user), f"{remote_python} {remote_root}/phase2_worker.py cold --plan {remote_root}/signed-plan.json {common} --workspace-bytes {args.workspace_bytes} --cache-limit-bytes {args.cache_limit_bytes} --receipt {remote_root}/cache-cold.json"], 600)
        mark(LIVE_ORDER[7])
        local_plan.unlink()
        _run([*_ssh_base(public_ip, args.ssh_user), f"rm -f {remote_root}/signed-plan.json"])
        mark(LIVE_ORDER[8])
        _run([*_ssh_base(public_ip, args.ssh_user), f"env -i PATH=/usr/local/bin:/usr/bin:/bin {remote_python} {remote_root}/phase2_worker.py warm {common} --receipt {remote_root}/cache-warm.json"], 600)
        mark(LIVE_ORDER[9])
        network_command = (
            f"{remote_python} {remote_root}/phase2_worker.py network --run-id {args.run_id} --bucket {bucket} "
            f"--expected-vpc-uuid {storage['vpc_uuid']} --expected-vpc-cidr {storage['vpc_cidr']} "
            f"--expected-droplet-id {droplet_id} --controller-vpc-uuid {droplet['vpc_uuid']} "
            f"--controller-droplet-id {droplet['id']} --receipt {remote_root}/worker-network.json"
        )
        _run([*_ssh_base(public_ip, args.ssh_user), network_command], 60)
        _run(["scp", "-q", f"{remote}:{remote_root}/cache-cold.json", f"{remote}:{remote_root}/cache-warm.json", f"{remote}:{remote_root}/worker-network.json", str(runtime)])
        mark(LIVE_ORDER[10])

        _tf(tf, args.worker_dir, "destroy", "-auto-approve", "-input=false", timeout=600)
        state_after = subprocess.run(
            [tf, f"-chdir={args.worker_dir}", "state", "list"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout.strip()
        if state_after:
            raise ProtocolError("destroy left managed resources")
        mark(LIVE_ORDER[11])
        _run(["systemctl", "--user", "stop", unit_name])
        installed_unit.unlink(missing_ok=True)
        _run(["systemctl", "--user", "daemon-reload"])
        armed = False
        _tf(tf, args.worker_dir, "workspace", "select", "default")
        _tf(tf, args.worker_dir, "workspace", "delete", workspace)
        mark(LIVE_ORDER[12])
        write_private_json(controller_receipt, {
            "finished_at": int(time.time()), "phases": phases, "run_id": args.run_id,
            "status": "success", "version": "demo-phase2-controller-v1",
            "worker_receipts": [str(path) for path in worker_receipts],
        })
        return 0
    except Exception as exc:
        detail = str(exc) if isinstance(exc, ProtocolError) else f"unexpected_{type(exc).__name__}"
        write_private_json(controller_receipt, {
            "detail": detail, "finished_at": int(time.time()), "phases": phases,
            "run_id": args.run_id, "status": "error", "version": "demo-phase2-controller-v1",
            "worker_receipts": [str(path) for path in worker_receipts],
        })
        # Once armed, cleanup is deliberately left active on every failure.
        if not armed:
            pass
        raise ProtocolError(detail) from None


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build-pack")
    build.add_argument("--profile", choices=("tiny", "full"), required=True)
    build.add_argument("--out", type=Path, required=True)
    build.add_argument("--receipt", type=Path, required=True)
    commands.add_parser("dry-run")
    live = commands.add_parser("live-smoke")
    live.add_argument("--execute-live", dest="execute_live", action="store_const", const="--execute-live", required=True)
    live.add_argument("--run-id", required=True)
    live.add_argument("--authorization", type=Path, required=True)
    live.add_argument("--pack-receipt", type=Path, required=True)
    live.add_argument("--verification-pack-receipt", type=Path, required=True)
    live.add_argument("--worker-dir", type=Path, default=ROOT / "terraform/digitalocean-workers")
    live.add_argument("--storage-dir", type=Path, default=ROOT / "terraform/digitalocean-storage")
    live.add_argument("--runtime-dir", type=Path, default=ROOT / "artifacts/phase2")
    live.add_argument("--ssh-user", default="root")
    live.add_argument("--cache-root", default="/data/demo-cache")
    live.add_argument("--workspace-bytes", type=int, required=True)
    live.add_argument("--cache-limit-bytes", type=int, required=True)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "build-pack":
        return build_pack_command(args)
    if args.command == "dry-run":
        return dry_run_command()
    return live_smoke(args)


if __name__ == "__main__":
    raise SystemExit(main())
