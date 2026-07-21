"""Inactive Phase 2 controls, cleanup rendering, and evidence validation.

Nothing in this module applies Terraform, arms systemd, uploads an object, or
contacts DigitalOcean unless an explicit caller invokes the narrowly named
fetch/collect function.  The repository's Phase 2 build uses fixtures only.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Mapping

from .storage_protocol import ProtocolError, canonical_json, write_private_json

REGION = "ams3"
SIZE = "s-1vcpu-1gb"
DISK_GIB = 25
CAP_USD = 5.10
MAX_SECONDS = 20 * 60
RECEIPT_VERSION = "demo-storage-smoke-receipt-v1"
LIVE_ORDER = (
    "consume_authorization_and_create_workspace",
    "publish_and_verify_pack",
    "fetch_and_verify_size",
    "arm_and_verify_cleanup",
    "apply_once",
    "discover_worker",
    "presign_and_transfer_private_plan",
    "cold_cache",
    "delete_local_and_remote_plan",
    "warm_verify_zero_network",
    "collect_network_and_ray_evidence",
    "destroy_and_verify_zero_resources",
    "disarm_and_remove_workspace",
)


def _fsync_parent(path: Path) -> None:
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_size_payload(payload: Mapping[str, object], checked_at: int, now: int | None = None) -> dict[str, object]:
    now = int(time.time()) if now is None else now
    if abs(now - checked_at) > 60:
        raise ProtocolError("size result is not fresh enough for apply")
    sizes = payload.get("sizes")
    if not isinstance(sizes, list):
        raise ProtocolError("DigitalOcean size response schema is invalid")
    matches = [entry for entry in sizes if isinstance(entry, dict) and entry.get("slug") == SIZE]
    if len(matches) != 1:
        raise ProtocolError("required smoke size is unavailable or ambiguous")
    entry = matches[0]
    if entry.get("available") is not True or REGION not in entry.get("regions", []):
        raise ProtocolError("required smoke size is unavailable in AMS3")
    if not isinstance(entry.get("disk"), int) or int(entry["disk"]) < DISK_GIB:
        raise ProtocolError("required smoke size has less than 25 GiB disk")
    hourly = entry.get("price_hourly")
    if not isinstance(hourly, (int, float)) or hourly <= 0:
        raise ProtocolError("required smoke size price is invalid")
    return {"checked_at": checked_at, "disk_gib": entry["disk"], "price_hourly_usd": float(hourly), "region": REGION, "slug": SIZE}


def fetch_live_size(token: str, timeout: float = 10.0) -> tuple[dict[str, object], int]:
    """Fetch `/v2/sizes`; callers must pass the environment-only token."""
    if not token:
        raise ProtocolError("DIGITALOCEAN_TOKEN is required explicitly")
    request = urllib.request.Request(
        "https://api.digitalocean.com/v2/sizes?per_page=200",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
    except (OSError, urllib.error.URLError) as exc:
        raise ProtocolError(f"DigitalOcean size query failed ({type(exc).__name__})") from None
    if len(raw) > 2 * 1024 * 1024:
        raise ProtocolError("DigitalOcean size response exceeded byte limit")
    checked_at = int(time.time())
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("DigitalOcean size response is invalid JSON") from exc
    return validate_size_payload(payload, checked_at), checked_at


def validate_authorization(auth: Mapping[str, object], run_id: str, now: int | None = None) -> None:
    now = int(time.time()) if now is None else now
    expected = {
        "cluster_name": f"ray-{run_id}",
        "run_id": run_id,
        "region": REGION,
        "size_slug": SIZE,
        "worker_count": 1,
    }
    for key, value in expected.items():
        if auth.get(key) != value:
            raise ProtocolError("authorization is not bound to this exact smoke run")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{7,62}", run_id):
        raise ProtocolError("run ID is invalid")
    if (
        not isinstance(auth.get("expires_at"), int)
        or now >= int(auth["expires_at"])
        or int(auth["expires_at"]) - now > 900
    ):
        raise ProtocolError("authorization has expired")
    if not isinstance(auth.get("price_checked_at"), int) or int(auth["price_checked_at"]) > now:
        raise ProtocolError("authorization price timestamp is invalid")
    if int(auth.get("disk_gib", 0)) < DISK_GIB:
        raise ProtocolError("authorized size has insufficient disk")
    base = auth.get("spaces_base_usd")
    prior = auth.get("prior_authorized_usd")
    compute = auth.get("compute_rounded_usd")
    total = auth.get("total_authorized_usd")
    if not all(isinstance(value, (int, float)) and value >= 0 for value in (base, prior, compute, total)):
        raise ProtocolError("authorization cost fields are invalid")
    hourly = auth.get("price_hourly_usd")
    if not isinstance(hourly, (int, float)) or hourly <= 0:
        raise ProtocolError("authorization price is invalid")
    conservative = float(hourly)  # one full hour, despite 20-minute deadline
    if float(compute) < conservative or abs(float(total) - (float(base) + float(prior) + float(compute))) > 1e-9:
        raise ProtocolError("authorization does not conservatively account for cost")
    if float(total) > CAP_USD or float(auth.get("cap_usd", -1)) != CAP_USD:
        raise ProtocolError("authorization exceeds the approved cap")


def validate_live_recheck(auth: Mapping[str, object], size: Mapping[str, object], now: int | None = None) -> None:
    now = int(time.time()) if now is None else now
    if abs(now - int(size.get("checked_at", 0))) > 60:
        raise ProtocolError("live size recheck is not immediate enough for apply")
    if size.get("slug") != SIZE or size.get("region") != REGION or int(size.get("disk_gib", 0)) < DISK_GIB:
        raise ProtocolError("live size recheck differs from authorization")
    if float(size.get("price_hourly_usd", CAP_USD + 1)) > float(auth.get("compute_rounded_usd", -1)):
        raise ProtocolError("live compute price exceeds the consumed authorization")


def consume_authorization(auth_path: Path, ledger_dir: Path, run_id: str, now: int | None = None) -> Path:
    """Atomically consume once; the durable marker is retained on every outcome."""
    if stat_mode(auth_path) != 0o600:
        raise ProtocolError("authorization receipt must have mode 0600")
    try:
        auth = json.loads(auth_path.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("authorization receipt is unreadable") from exc
    if not isinstance(auth, dict):
        raise ProtocolError("authorization receipt schema is invalid")
    validate_authorization(auth, run_id, now)
    ledger_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    marker = ledger_dir / f"{run_id}.consumed.json"
    try:
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise ProtocolError("authorization was already consumed; retry/reapply is forbidden") from None
    with os.fdopen(fd, "wb") as handle:
        handle.write(canonical_json({"authorization_sha256": _sha256(auth_path.read_bytes()), "consumed_at": int(time.time()), "run_id": run_id}))
        handle.flush()
        os.fsync(handle.fileno())
    _fsync_parent(marker)
    return marker


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


def _sha256(value: bytes) -> str:
    import hashlib
    return hashlib.sha256(value).hexdigest()


def render_cleanup_bundle(
    root: Path,
    run_id: str,
    workspace: str,
    worker_dir: Path,
    deadline_epoch: int,
    tf_executable: str,
) -> tuple[Path, Path]:
    """Render, but never arm, a task-scoped independent cleanup unit."""
    now = int(time.time())
    if deadline_epoch <= now or deadline_epoch - now > MAX_SECONDS:
        raise ProtocolError("cleanup deadline must be absolute and within 20 minutes")
    if workspace != f"smoke-{run_id}" or not worker_dir.is_absolute() or not Path(tf_executable).is_absolute():
        raise ProtocolError("cleanup target is not isolated to the exact smoke workspace")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    script = root / "cleanup.sh"
    unit = root / f"ray-storage-smoke-cleanup-{run_id}.service"
    script_body = f"""#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
run_id={json.dumps(run_id)}
workspace={json.dumps(workspace)}
worker_dir={json.dumps(str(worker_dir))}
receipt_dir={json.dumps(str(root))}
deadline_epoch={deadline_epoch}
tf_executable={json.dumps(tf_executable)}
status=error
detail=cleanup_failed
finish() {{
  RUN_ID="$run_id" STATUS="$status" DETAIL="$detail" RECEIPT_DIR="$receipt_dir" python3 - <<'PY'
import json, os, pathlib, time
p = pathlib.Path(os.environ['RECEIPT_DIR']) / 'cleanup-terminal.json'
t = p.with_suffix('.tmp')
with t.open('w') as f:
    json.dump({{'version':'{RECEIPT_VERSION}','phase':'cleanup','run_id':os.environ['RUN_ID'],'status':os.environ['STATUS'],'detail':os.environ['DETAIL'],'finished_at':int(time.time())}},f,sort_keys=True,separators=(',',':'))
    f.write('\\n'); f.flush(); os.fsync(f.fileno())
os.chmod(t,0o600); t.replace(p)
d = os.open(p.parent, os.O_RDONLY | os.O_DIRECTORY)
try: os.fsync(d)
finally: os.close(d)
PY
}}
trap finish EXIT
remaining=$((deadline_epoch - $(date +%s)))
(( remaining <= 0 )) || sleep "$remaining"
env_file="$(cd "$worker_dir/../.." && pwd)/.env"
[[ -f "$env_file" ]] || {{ detail=missing_ignored_env; exit 1; }}
set -a
source "$env_file"
set +a
cd "$worker_dir"
"$tf_executable" workspace select "$workspace"
for delay in 0 10 30 60; do
  (( delay == 0 )) || sleep "$delay"
  if "$tf_executable" destroy -auto-approve -input=false >/dev/null 2>&1 && [[ -z "$("$tf_executable" state list 2>/dev/null)" ]]; then
    status=success; detail=zero_managed_resources; exit 0
  fi
done
exit 1
"""
    unit_body = f"""[Unit]
Description=Ray storage smoke cleanup {run_id}

[Service]
Type=oneshot
ExecStart={script}
TimeoutStartSec=30min
Environment=PATH=/usr/local/bin:/usr/bin:/bin
StandardOutput=null
StandardError=null
"""
    script.write_text(script_body)
    os.chmod(script, 0o700)
    unit.write_text(unit_body)
    os.chmod(unit, 0o600)
    write_private_json(root / "cleanup-render.json", {
        "deadline_epoch": deadline_epoch,
        "full_destroy": True,
        "never_target": True,
        "retry_scope": "cleanup_only",
        "run_id": run_id,
        "unit": str(unit),
        "workspace": workspace,
        "tf_executable": tf_executable,
    })
    return script, unit


def validate_controller_crosscheck(
    terraform: Mapping[str, object], api: Mapping[str, object], expected_vpc_uuid: str
) -> None:
    if terraform.get("selected_vpc_uuid") != expected_vpc_uuid:
        raise ProtocolError("Terraform selected VPC differs from storage authority")
    tf_ids = sorted(str(value) for value in terraform.get("droplet_ids", []))
    api_ids = sorted(str(value) for value in api.get("droplet_ids", []))
    if tf_ids != api_ids or len(tf_ids) != 1 or api.get("vpc_uuid") != expected_vpc_uuid:
        raise ProtocolError("Terraform and DigitalOcean API worker identity differ")


def validate_network_receipt(receipt: Mapping[str, object]) -> None:
    """Validate controller/worker observations, private routes, and Ray identity."""
    expected = receipt.get("expected")
    controller = receipt.get("controller_observed")
    worker = receipt.get("worker_observed")
    if not all(isinstance(value, dict) for value in (expected, controller, worker)):
        raise ProtocolError("network receipt observation schema is invalid")
    assert isinstance(expected, dict) and isinstance(controller, dict) and isinstance(worker, dict)
    sources = receipt.get("sources")
    if not isinstance(sources, dict) or any(not sources.get(group) for group in ("expected", "controller_observed", "worker_observed")):
        raise ProtocolError("network receipt sources are incomplete")
    if "vpc_uuid" in worker:
        raise ProtocolError("worker must not overclaim observation of a VPC UUID")
    if expected.get("vpc_uuid") != controller.get("vpc_uuid"):
        raise ProtocolError("controller VPC observation differs from expected authority")
    if expected.get("droplet_id") != controller.get("droplet_id") or expected.get("droplet_id") != worker.get("droplet_id"):
        raise ProtocolError("Droplet identity observations disagree")
    if worker.get("resolved_endpoint") != expected.get("spaces_endpoint"):
        raise ProtocolError("resolved Spaces endpoint differs from expected endpoint")
    try:
        network = ipaddress.ip_network(str(expected.get("vpc_cidr")), strict=False)
        private_ip = ipaddress.ip_address(str(worker.get("metadata_private_ip")))
    except ValueError as exc:
        raise ProtocolError("network receipt contains malformed IP or CIDR evidence") from exc
    if private_ip not in network:
        raise ProtocolError("metadata private IP is outside expected VPC")
    interface = worker.get("private_interface")
    if not interface or worker.get("interface_match_count") != 1:
        raise ProtocolError("metadata private interface is ambiguous")
    answers = worker.get("dns_answers")
    route_evidence = worker.get("routes")
    if not isinstance(answers, list) or not answers or not isinstance(route_evidence, list):
        raise ProtocolError("DNS or route evidence is missing")
    try:
        parsed_answers = [str(ipaddress.ip_address(str(answer))) for answer in answers]
    except ValueError as exc:
        raise ProtocolError("DNS evidence contains a malformed address") from exc
    if len(set(parsed_answers)) != len(parsed_answers):
        raise ProtocolError("DNS evidence contains duplicate addresses")
    by_answer = {entry.get("answer"): entry for entry in route_evidence if isinstance(entry, dict)}
    if set(by_answer) != set(parsed_answers) or len(route_evidence) != len(parsed_answers):
        raise ProtocolError("route evidence does not exactly cover every DNS answer")
    resolver = worker.get("resolver")
    if not isinstance(resolver, dict):
        raise ProtocolError("resolver evidence is missing")
    if resolver.get("effective_link") != interface or not resolver.get("link_status") or not resolver.get("resolv_conf"):
        raise ProtocolError("effective resolver link evidence is incomplete")
    if not isinstance(resolver.get("upstream"), list) or not resolver.get("upstream"):
        raise ProtocolError("resolver upstream evidence is incomplete")
    for answer in parsed_answers:
        route = by_answer.get(answer)
        if not route or route.get("dev") != interface or route.get("src") != str(private_ip):
            raise ProtocolError("Spaces answer uses a public or ambiguous route")
        if route.get("vpc_route_present") is not True:
            raise ProtocolError("expected VPC route evidence is absent")
    ray = worker.get("ray")
    if not isinstance(ray, dict) or ray.get("match_count") != 1 or ray.get("alive") is not True:
        raise ProtocolError("Ray node identity is absent or ambiguous")
    if ray.get("node_name") != worker.get("hostname") or ray.get("node_address") != worker.get("tailscale_ip"):
        raise ProtocolError("Ray node does not match hostname plus Tailscale IP")
    if ray.get("node_address") == worker.get("metadata_private_ip"):
        raise ProtocolError("Ray identity incorrectly uses the DO private IP")


def run_json(command: list[str], timeout: float = 5.0) -> object:
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=timeout)
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"evidence command failed ({command[0]}:{type(exc).__name__})") from None


def _run_text(command: list[str], timeout: float = 5.0, max_bytes: int = 256 * 1024) -> str:
    try:
        result = subprocess.run(command, check=True, capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProtocolError(f"evidence command failed ({command[0]}:{type(exc).__name__})") from None
    if len(result.stdout) > max_bytes:
        raise ProtocolError("evidence command exceeded byte limit")
    return result.stdout.decode("utf-8", "strict").strip()


def _metadata(path: str, timeout: float = 3.0) -> str:
    url = "http://169.254.169.254/metadata/v1/" + path
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            raw = response.read(64 * 1024 + 1)
    except (OSError, urllib.error.URLError) as exc:
        raise ProtocolError(f"metadata query failed ({type(exc).__name__})") from None
    if len(raw) > 64 * 1024:
        raise ProtocolError("metadata response exceeded byte limit")
    return raw.decode("utf-8", "strict").strip()


def _collect_worker_network_receipt(
    path: Path,
    run_id: str,
    bucket: str,
    expected_vpc_uuid: str,
    expected_vpc_cidr: str,
    expected_droplet_id: str,
    controller_vpc_uuid: str,
    controller_droplet_id: str,
) -> None:
    """Collect one bounded worker receipt; this is never called by offline checks."""
    network = ipaddress.ip_network(expected_vpc_cidr, strict=False)
    droplet_id = _metadata("id")
    private_ip = _metadata("interfaces/private/0/ipv4/address")
    gateway = _metadata("interfaces/private/0/ipv4/gateway")
    netmask = _metadata("interfaces/private/0/ipv4/netmask")
    metadata_dns = _metadata("dns/nameservers")
    addresses = run_json(["ip", "-j", "address", "show"])
    if not isinstance(addresses, list):
        raise ProtocolError("ip address evidence schema is invalid")
    matches = []
    for interface in addresses:
        if not isinstance(interface, dict):
            continue
        if any(item.get("local") == private_ip for item in interface.get("addr_info", []) if isinstance(item, dict)):
            matches.append(str(interface.get("ifname")))
    interface = matches[0] if len(matches) == 1 else ""
    endpoint = f"{bucket}.ams3.digitaloceanspaces.com"
    getent = _run_text(["getent", "ahosts", endpoint])
    try:
        dns_answers = sorted({str(ipaddress.ip_address(line.split()[0])) for line in getent.splitlines() if line.split()})
    except ValueError as exc:
        raise ProtocolError("resolver returned a malformed address") from exc
    all_routes = run_json(["ip", "-j", "route", "show", "table", "all"])
    vpc_route_present = any(
        isinstance(route, dict)
        and route.get("dst") == str(network)
        and route.get("dev") == interface
        for route in (all_routes if isinstance(all_routes, list) else [])
    )
    routes = []
    for answer in dns_answers:
        route_get = run_json(["ip", "-j", "route", "get", answer])
        if not isinstance(route_get, list) or len(route_get) != 1 or not isinstance(route_get[0], dict):
            raise ProtocolError("route-get evidence is ambiguous")
        route = route_get[0]
        routes.append({"answer": answer, "dev": route.get("dev"), "gateway": route.get("gateway"), "src": route.get("prefsrc"), "vpc_route_present": vpc_route_present})
    hostname = _run_text(["hostname"])
    tailscale_ip = _run_text(["tailscale", "ip", "-4"])
    ray_code = (
        "import json,ray;ray.init(address='auto',logging_level='ERROR');"
        "print(json.dumps(ray.nodes(),sort_keys=True))"
    )
    ray_nodes = json.loads(_run_text([sys.executable, "-c", ray_code], timeout=10.0, max_bytes=1024 * 1024))
    ray_matches = [
        node for node in ray_nodes
        if node.get("Alive") is True
        and node.get("NodeName") == hostname
        and node.get("NodeManagerAddress") == tailscale_ip
    ]
    ray_evidence = {
        "match_count": len(ray_matches),
        "alive": ray_matches[0].get("Alive") if len(ray_matches) == 1 else None,
        "node_id": ray_matches[0].get("NodeID") if len(ray_matches) == 1 else None,
        "node_name": ray_matches[0].get("NodeName") if len(ray_matches) == 1 else None,
        "node_address": ray_matches[0].get("NodeManagerAddress") if len(ray_matches) == 1 else None,
    }
    worker = {
        "dns_answers": dns_answers,
        "droplet_id": droplet_id,
        "hostname": hostname,
        "interface_match_count": len(matches),
        "metadata_gateway": gateway,
        "metadata_netmask": netmask,
        "metadata_private_ip": private_ip,
        "private_interface": interface,
        "ray": ray_evidence,
        "resolver": {
            "effective_link": interface,
            "link_status": _run_text(["resolvectl", "status", interface]),
            "resolv_conf": Path("/etc/resolv.conf").read_text()[:64 * 1024],
            "upstream": metadata_dns.splitlines(),
        },
        "routes": routes,
        "resolved_endpoint": endpoint,
        "tailscale_ip": tailscale_ip,
    }
    receipt = {
        "controller_observed": {"droplet_id": controller_droplet_id, "vpc_uuid": controller_vpc_uuid},
        "expected": {
            "droplet_id": expected_droplet_id,
            "spaces_endpoint": endpoint,
            "vpc_cidr": str(network),
            "vpc_uuid": expected_vpc_uuid,
        },
        "run_id": run_id,
        "phase": "worker-network-ray",
        "sources": {
            "controller_observed": "DigitalOcean API cross-check",
            "expected": "reviewed storage and worker Terraform outputs",
            "worker_observed": "metadata, iproute2, systemd-resolved, getent, tailscale, Ray GCS",
        },
        "status": "success",
        "version": RECEIPT_VERSION,
        "worker_observed": worker,
    }
    receipt["finished_at"] = int(time.time())
    validate_network_receipt(receipt)
    write_private_json(path, receipt)


def collect_worker_network_receipt(
    path: Path,
    run_id: str,
    bucket: str,
    expected_vpc_uuid: str,
    expected_vpc_cidr: str,
    expected_droplet_id: str,
    controller_vpc_uuid: str,
    controller_droplet_id: str,
) -> None:
    """Collect one receipt and durably record every sanitized failure."""
    try:
        _collect_worker_network_receipt(
            path,
            run_id,
            bucket,
            expected_vpc_uuid,
            expected_vpc_cidr,
            expected_droplet_id,
            controller_vpc_uuid,
            controller_droplet_id,
        )
    except ProtocolError as exc:
        terminal_receipt(path, run_id, "worker-network-ray", "error", str(exc))
        raise
    except Exception as exc:
        detail = f"worker evidence collection failed ({type(exc).__name__})"
        terminal_receipt(path, run_id, "worker-network-ray", "error", detail)
        raise ProtocolError(detail) from None


def terminal_receipt(path: Path, run_id: str, phase: str, status: str, detail: str, droplet_id: str | None = None) -> None:
    if status not in {"success", "error"}:
        raise ProtocolError("terminal receipt status is invalid")
    value = {
        "detail": detail,
        "droplet_id": droplet_id,
        "finished_at": int(time.time()),
        "phase": phase,
        "run_id": run_id,
        "status": status,
        "version": RECEIPT_VERSION,
    }
    write_private_json(path, value)
