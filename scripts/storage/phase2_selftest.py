#!/usr/bin/env python3
"""Single offline acceptance entrypoint for the Phase 2 code-only build."""

from __future__ import annotations

import copy
import json
import multiprocessing
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path

from spotify_ray_infra.phase2_control import (
    CAP_USD,
    LIVE_ORDER,
    RECEIPT_VERSION,
    SIZE,
    consume_authorization,
    render_cleanup_bundle,
    validate_authorization,
    validate_controller_crosscheck,
    validate_network_receipt,
    validate_size_payload,
    validate_live_recheck,
)
from spotify_ray_infra.storage_protocol import (
    MANIFEST_NAME,
    ProtocolError,
    _descriptor,
    _locked,
    _remove_stale_partials,
    boto3_bronze_client,
    build_pack,
    canonical_json,
    evict_cache,
    make_download_plan,
    materialize_cache,
    parse_manifest,
    presign_get_plan,
    publish_and_verify,
    sha256_bytes,
    verify_pack,
    warm_verify,
    write_private_json,
)


def expect_error(label: str, action) -> None:
    try:
        action()
    except (ProtocolError, BlockingIOError):
        return
    raise AssertionError(f"expected rejection: {label}")


def hold_lock(path: str, ready) -> None:
    with _locked(Path(path)):
        ready.send(True)
        time.sleep(3)


def signed_url(bucket: str, key: str) -> str:
    from urllib.parse import quote
    return f"https://{bucket}.ams3.digitaloceanspaces.com/{quote(key, safe='/')}?X-Amz-Signature=redacted"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ray-phase2-selftest.") as raw_tmp:
        tmp = Path(raw_tmp)
        controller = Path(__file__).with_name("phase2.py")
        proof = json.loads(subprocess.run(
            [sys.executable, str(controller), "dry-run"], check=True, capture_output=True, text=True,
        ).stdout)
        assert proof["apply_count"] == 1
        assert proof["plan_deleted_before_warm"] is True
        assert proof["destroy_before_disarm"] is True
        assert proof["ordered_phases"] == list(LIVE_ORDER)
        assert sum(item["command"] == "tofu apply exactly once" for item in proof["commands"]) == 1
        cli_pack = tmp / "cli-pack"
        cli_receipt = tmp / "cli-pack-receipt.json"
        subprocess.run(
            [sys.executable, str(controller), "build-pack", "--profile", "tiny", "--out", str(cli_pack), "--receipt", str(cli_receipt)],
            check=True, capture_output=True, text=True,
        )
        cli_pack_receipt = json.loads(cli_receipt.read_bytes())
        assert cli_pack_receipt["profile"] == "tiny" and cli_pack_receipt["object_count"] == 2
        pack_a, pack_b = tmp / "pack-a", tmp / "pack-b"
        result_a = build_pack(pack_a, "tiny")
        result_b = build_pack(pack_b, "tiny")
        assert result_a == result_b
        for left in pack_a.rglob("*"):
            if left.is_file():
                assert left.read_bytes() == (pack_b / left.relative_to(pack_a)).read_bytes()
        manifest_raw = (pack_a / MANIFEST_NAME).read_bytes()
        manifest = parse_manifest(manifest_raw, result_a["test_pack_hash"], result_a["manifest_sha256"])
        assert manifest["prefix"] == f"smoke/{result_a['test_pack_hash']}/"

        mutated = bytearray(manifest_raw)
        mutated[-2] ^= 1
        expect_error("manifest mutation", lambda: parse_manifest(bytes(mutated), result_a["test_pack_hash"], result_a["manifest_sha256"]))
        for bad_path in ("../escape.parquet", "/absolute.parquet", "a//b.parquet"):
            bad = copy.deepcopy(manifest)
            bad["objects"][0]["path"] = bad_path
            descriptor = _descriptor(bad["objects"])
            bad_hash = sha256_bytes(canonical_json(descriptor))
            bad["test_pack_hash"] = bad_hash
            bad["prefix"] = f"smoke/{bad_hash}/"
            raw = canonical_json(bad)
            expect_error("path traversal", lambda raw=raw, h=bad_hash: parse_manifest(raw, h, sha256_bytes(raw)))
        duplicate = copy.deepcopy(manifest)
        duplicate["objects"].append(copy.deepcopy(duplicate["objects"][0]))
        descriptor = _descriptor(duplicate["objects"])
        duplicate_hash = sha256_bytes(canonical_json(descriptor))
        duplicate["test_pack_hash"] = duplicate_hash
        duplicate["prefix"] = f"smoke/{duplicate_hash}/"
        duplicate_raw = canonical_json(duplicate)
        expect_error("duplicate", lambda: parse_manifest(duplicate_raw, duplicate_hash, sha256_bytes(duplicate_raw)))

        bucket = "phase2-offline-test"
        plan = make_download_plan(
            bucket, manifest, result_a["manifest_sha256"], int(time.time()) + 300,
            lambda key: signed_url(bucket, key),
        )
        plan_path = tmp / "runtime" / "signed-plan.json"
        write_private_json(plan_path, plan)
        assert plan_path.stat().st_mode & 0o777 == 0o600
        source = {
            item["url"]: (pack_a / item["path"]).read_bytes()
            for item in plan["downloads"]
        }
        fetch_count = 0

        def fetch(url: str, destination: Path, max_bytes: int) -> None:
            nonlocal fetch_count
            fetch_count += 1
            value = source[url]
            if len(value) > max_bytes:
                raise ProtocolError("fixture exceeded bound")
            destination.write_bytes(value)

        cache = tmp / "cache"
        snapshot_bytes = sum(item["size"] for item in manifest["objects"])
        cold = materialize_cache(
            cache, plan, result_a["test_pack_hash"], result_a["manifest_sha256"],
            workspace_bytes=1024, cache_limit_bytes=snapshot_bytes * 3, fetch=fetch,
            free_bytes=snapshot_bytes * 4,
        )
        assert cold.reused is False
        cold_fetches = fetch_count
        plan_path.unlink()
        warm_verify(cache, result_a["test_pack_hash"], result_a["manifest_sha256"])
        assert fetch_count == cold_fetches
        victim = next(path for path in cold.path.rglob("*.parquet"))
        original = victim.read_bytes()
        victim.write_bytes(original[:-1])
        expect_error("truncated cache", lambda: warm_verify(cache, result_a["test_pack_hash"], result_a["manifest_sha256"]))
        victim.write_bytes(original)
        extra = cold.path / "unexpected"
        extra.write_text("x")
        expect_error("cache extras", lambda: verify_pack(cold.path, result_a["test_pack_hash"], result_a["manifest_sha256"]))
        extra.unlink()

        empty_cache = tmp / "insufficient"
        expect_error(
            "insufficient disk",
            lambda: materialize_cache(
                empty_cache, plan, result_a["test_pack_hash"], result_a["manifest_sha256"],
                1024, snapshot_bytes * 3, fetch, free_bytes=1,
            ),
        )
        duplicate_plan = copy.deepcopy(plan)
        duplicate_plan["downloads"].append(copy.deepcopy(duplicate_plan["downloads"][0]))
        expect_error(
            "duplicate download plan path",
            lambda: materialize_cache(
                tmp / "duplicate-plan", duplicate_plan, result_a["test_pack_hash"], result_a["manifest_sha256"],
                1024, snapshot_bytes * 3, fetch, free_bytes=snapshot_bytes * 4,
            ),
        )
        evict_root = tmp / "evict"
        locked = evict_root / "old-locked"
        locked.mkdir(parents=True)
        (locked / ".ready").write_text("{}")
        (locked / "payload").write_bytes(b"x" * 4096)
        lock_path = evict_root / ".locks" / "old-locked.lock"
        parent, child = multiprocessing.Pipe(False)
        process = multiprocessing.Process(target=hold_lock, args=(str(lock_path), child))
        process.start()
        assert parent.recv() is True
        expect_error("locked eviction", lambda: evict_cache(evict_root, 4096, 4096, "current"))
        process.terminate()
        process.join()
        assert locked.exists()

        active_partial = evict_root / f".{result_a['test_pack_hash']}.partial.999.fixture"
        active_partial.mkdir()
        os.utime(active_partial, (1, 1))
        parent, child = multiprocessing.Pipe(False)
        process = multiprocessing.Process(
            target=hold_lock,
            args=(str(evict_root / ".locks" / f"{result_a['test_pack_hash']}.lock"), child),
        )
        process.start()
        assert parent.recv() is True
        _remove_stale_partials(evict_root, 1)
        process.terminate()
        process.join()
        assert active_partial.exists()

        fake_calls = []
        fake_boto3 = types.ModuleType("boto3")
        fake_boto3.client = lambda *args, **kwargs: fake_calls.append((args, kwargs)) or object()
        fake_botocore = types.ModuleType("botocore")
        fake_config_module = types.ModuleType("botocore.config")

        class FakeConfig:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

        fake_config_module.Config = FakeConfig
        previous = {name: sys.modules.get(name) for name in ("boto3", "botocore", "botocore.config")}
        sys.modules.update({"boto3": fake_boto3, "botocore": fake_botocore, "botocore.config": fake_config_module})
        try:
            boto3_bronze_client({
                "BRONZE_SPACES_ACCESS_KEY_ID": "fake-access",
                "BRONZE_SPACES_SECRET_ACCESS_KEY": "fake-secret",
                "AWS_ACCESS_KEY_ID": "wrong-role",
                "SPACES_ACCESS_KEY_ID": "wrong-role",
            })
        finally:
            for name, value in previous.items():
                if value is None:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = value
        assert len(fake_calls) == 1
        assert fake_calls[0][1]["aws_access_key_id"] == "fake-access"
        assert fake_calls[0][1]["config"].kwargs["signature_version"] == "s3v4"
        assert fake_calls[0][1]["config"].kwargs["s3"] == {"addressing_style": "virtual"}
        expect_error(
            "wrong-role credentials",
            lambda: boto3_bronze_client({
                "AWS_ACCESS_KEY_ID": "wrong-role", "AWS_SECRET_ACCESS_KEY": "wrong-role",
                "SPACES_ACCESS_KEY_ID": "wrong-role", "SPACES_SECRET_ACCESS_KEY": "wrong-role",
            }),
        )

        class FakePublisher:
            def __init__(self):
                self.uploads = 0

            def upload_file(self, *args, **kwargs):
                self.uploads += 1

        publish_root = tmp / "bad-publish"
        shutil.copytree(pack_a, publish_root)
        bad_publish_manifest = copy.deepcopy(manifest)
        bad_publish_manifest["objects"][0]["path"] = "../exfiltrate"
        bad_descriptor = _descriptor(bad_publish_manifest["objects"])
        bad_pack_hash = sha256_bytes(canonical_json(bad_descriptor))
        bad_publish_manifest["test_pack_hash"] = bad_pack_hash
        bad_publish_manifest["prefix"] = f"smoke/{bad_pack_hash}/"
        bad_publish_raw = canonical_json(bad_publish_manifest)
        (publish_root / MANIFEST_NAME).write_bytes(bad_publish_raw)
        fake_publisher = FakePublisher()
        expect_error(
            "publication traversal",
            lambda: publish_and_verify(fake_publisher, bucket, publish_root, bad_pack_hash, sha256_bytes(bad_publish_raw)),
        )
        assert fake_publisher.uploads == 0

        class FakeSigner:
            def __init__(self):
                self.calls = []

            def generate_presigned_url(self, method, Params, ExpiresIn, HttpMethod):
                self.calls.append((method, Params, ExpiresIn, HttpMethod))
                return signed_url(Params["Bucket"], Params["Key"])

        fake_signer = FakeSigner()
        presigned = presign_get_plan(fake_signer, bucket, manifest, result_a["manifest_sha256"], 300)
        assert fake_signer.calls and all(call[0] == "get_object" and call[3] == "GET" for call in fake_signer.calls)
        redacted_plan = copy.deepcopy(presigned)
        for item in redacted_plan["downloads"]:
            item["url"] = "<redacted>"
        assert "X-Amz-Signature" not in canonical_json(redacted_plan).decode()

        now = int(time.time())
        positive_payload = {"sizes": [{"slug": SIZE, "available": True, "regions": ["ams3"], "disk": 25, "price_hourly": 0.01}]}
        size = validate_size_payload(positive_payload, now, now)
        for changed in (
            {"available": False}, {"regions": ["nyc3"]}, {"disk": 24}, {"price_hourly": 0},
        ):
            payload = copy.deepcopy(positive_payload)
            payload["sizes"][0].update(changed)
            expect_error("bad size", lambda payload=payload: validate_size_payload(payload, now, now))

        run_id = "phase2-test-0001"
        auth = {
            "cap_usd": CAP_USD, "cluster_name": f"ray-{run_id}", "compute_rounded_usd": 0.01, "expires_at": now + 300,
            "price_checked_at": now, "price_hourly_usd": 0.01, "disk_gib": 25,
            "prior_authorized_usd": 0.0, "region": "ams3",
            "run_id": run_id, "size_slug": SIZE, "spaces_base_usd": 5.0,
            "total_authorized_usd": 5.01, "worker_count": 1,
        }
        auth_path = tmp / "authorization.json"
        write_private_json(auth_path, auth)
        marker = consume_authorization(auth_path, tmp / "ledger", run_id, now)
        assert marker.exists()
        expect_error("authorization reuse", lambda: consume_authorization(auth_path, tmp / "ledger", run_id, now))
        over = dict(auth, total_authorized_usd=5.11, compute_rounded_usd=0.11)
        expect_error("over budget", lambda: validate_authorization(over, run_id, now))
        validate_live_recheck(auth, size, now)
        expensive = dict(size, price_hourly_usd=0.02)
        expect_error("price increased after consumption", lambda: validate_live_recheck(auth, expensive, now))

        cleanup_root = tmp / "cleanup"
        script, unit = render_cleanup_bundle(
            cleanup_root, run_id, f"smoke-{run_id}", Path("/tmp/workers"), now + 600, "/usr/bin/tofu"
        )
        rendered = script.read_text() + unit.read_text()
        assert "-target" not in rendered and "fake-secret" not in rendered
        assert '"$tf_executable" destroy' in rendered and '"$tf_executable" state list' in rendered
        assert "TimeoutStartSec=30min" in rendered and "os.fsync(f.fileno())" in rendered and "os.fsync(d)" in rendered
        assert LIVE_ORDER.index("fetch_and_verify_size") < LIVE_ORDER.index("arm_and_verify_cleanup") < LIVE_ORDER.index("apply_once")

        expected_vpc = "12345678-1234-4234-8234-123456789abc"
        validate_controller_crosscheck(
            {"selected_vpc_uuid": expected_vpc, "droplet_ids": ["42"]},
            {"vpc_uuid": expected_vpc, "droplet_ids": ["42"]}, expected_vpc,
        )
        receipt = {
            "finished_at": now,
            "phase": "worker-network-ray",
            "run_id": run_id,
            "status": "success",
            "version": RECEIPT_VERSION,
            "expected": {
                "vpc_uuid": expected_vpc, "vpc_cidr": "10.10.0.0/20", "droplet_id": "42",
                "spaces_endpoint": "phase2-offline-test.ams3.digitaloceanspaces.com",
            },
            "controller_observed": {"vpc_uuid": expected_vpc, "droplet_id": "42"},
            "sources": {
                "expected": "fixture authority", "controller_observed": "fixture API", "worker_observed": "fixture worker",
            },
            "worker_observed": {
                "droplet_id": "42", "metadata_private_ip": "10.10.0.5",
                "metadata_gateway": "10.10.0.1", "metadata_netmask": "255.255.240.0",
                "private_interface": "ens7", "interface_match_count": 1,
                "resolver": {
                    "resolv_conf": "stub", "effective_link": "ens7", "link_status": "DNS Servers: 10.10.15.254",
                    "upstream": ["10.10.15.254"],
                },
                "dns_answers": ["203.0.113.8"],
                "resolved_endpoint": "phase2-offline-test.ams3.digitaloceanspaces.com",
                "routes": [{"answer": "203.0.113.8", "dev": "ens7", "src": "10.10.0.5", "vpc_route_present": True}],
                "hostname": "ray-smoke-worker-01", "tailscale_ip": "100.64.0.2",
                "ray": {"match_count": 1, "alive": True, "node_id": "node-1", "node_name": "ray-smoke-worker-01", "node_address": "100.64.0.2"},
            },
        }
        validate_network_receipt(receipt)
        for mutation in (
            lambda value: value["worker_observed"].update(private_interface="eth1", interface_match_count=2),
            lambda value: value["worker_observed"]["routes"][0].update(dev="eth0", src="192.0.2.2"),
            lambda value: value["worker_observed"]["ray"].update(match_count=2),
            lambda value: value["worker_observed"].pop("resolver"),
            lambda value: value["worker_observed"].update(resolved_endpoint="wrong.example"),
            lambda value: value["worker_observed"].update(vpc_uuid=expected_vpc),
        ):
            bad = copy.deepcopy(receipt)
            mutation(bad)
            expect_error("network ambiguity/public route", lambda bad=bad: validate_network_receipt(bad))

    print("Phase 2 offline selftest: PASS (no live API, upload, apply, cleanup arm, or full pack).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
