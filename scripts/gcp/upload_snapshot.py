#!/usr/bin/env python3
"""Explicit, immutable GCS snapshot upload using generation preconditions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from snapshot_manifest import ManifestError, crc32c, digest, validate

PROJECT = "example-project"
BUCKETS = {
    "bronze": f"{PROJECT}-bronze",
    "silver": f"{PROJECT}-silver",
}
PUBLISHER = f"data-publisher@{PROJECT}.iam.gserviceaccount.com"


def run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, capture_output=capture, text=True)


def describe(uri: str, identity: str) -> dict[str, Any]:
    completed = run(
        [
            "gcloud",
            "storage",
            "objects",
            "describe",
            uri,
            "--format=json",
            f"--impersonate-service-account={identity}",
        ],
        capture=True,
    )
    value = json.loads(completed.stdout)
    if not isinstance(value, dict):
        raise ManifestError(f"invalid GCS metadata response for {uri}")
    return value


def verify_remote(uri: str, expected: dict[str, Any], identity: str) -> None:
    observed = describe(uri, identity)
    metadata = observed.get("metadata") or observed.get("custom_fields") or {}
    observed_crc32c = observed.get("crc32c") or observed.get("crc32c_hash")
    if (
        int(observed.get("size", -1)) != expected["size"]
        or observed_crc32c != expected["crc32c"]
        or metadata.get("sha256") != expected["sha256"]
    ):
        raise ManifestError(f"uploaded object verification failed: {uri}")


def upload(local: Path, uri: str, expected: dict[str, Any], identity: str) -> None:
    run(
        [
            "gcloud",
            "storage",
            "cp",
            str(local),
            uri,
            "--if-generation-match=0",
            f"--custom-metadata=sha256={expected['sha256']}",
            f"--impersonate-service-account={identity}",
            "--quiet",
        ]
    )
    verify_remote(uri, expected, identity)


def file_metadata(path: Path) -> dict[str, Any]:
    return {"size": path.stat().st_size, "sha256": digest(path), "crc32c": crc32c(path)}


def private_write(path: Path, payload: dict[str, Any]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true", help="required live-mutation gate")
    parser.add_argument("--layer", choices=("bronze", "silver"), required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--impersonate-service-account", required=True)
    args = parser.parse_args()
    if not args.execute:
        print("snapshot-upload: refusing live upload without --execute")
        return 2
    try:
        if args.bucket != BUCKETS[args.layer]:
            raise ManifestError(f"bucket must be exactly {BUCKETS[args.layer]} for layer {args.layer}")
        if args.impersonate_service_account != PUBLISHER:
            raise ManifestError(f"publisher identity must be exactly {PUBLISHER}")
        manifest = json.loads(args.manifest.read_text())
        validate(manifest, args.root)
        snapshot_id = manifest["snapshot_id"]
        prefix = f"gs://{args.bucket}/{args.layer}/snapshots/{snapshot_id}"
        for item in manifest["objects"]:
            upload(args.root / item["name"], f"{prefix}/objects/{item['name']}", item, args.impersonate_service_account)
        upload(args.manifest, f"{prefix}/manifest.json", file_metadata(args.manifest), args.impersonate_service_account)
        with tempfile.TemporaryDirectory(prefix="gcp-snapshot-commit-") as temp_dir:
            commit = Path(temp_dir) / "COMMITTED.json"
            private_write(
                commit,
                {
                    "schema": "gcp-snapshot-commit-v1",
                    "snapshot_id": snapshot_id,
                    "manifest_sha256": hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                    "object_count": len(manifest["objects"]),
                    "total_bytes": sum(item["size"] for item in manifest["objects"]),
                },
            )
            upload(commit, f"{prefix}/COMMITTED.json", file_metadata(commit), args.impersonate_service_account)
        print(f"snapshot-upload: committed {prefix}")
    except (OSError, KeyError, json.JSONDecodeError, ManifestError, subprocess.CalledProcessError) as exc:
        print(f"snapshot-upload: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
