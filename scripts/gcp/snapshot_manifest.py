#!/usr/bin/env python3
"""Build and verify deterministic immutable snapshot manifests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from collections.abc import Iterable
from pathlib import Path, PurePosixPath
from typing import Any


class ManifestError(ValueError):
    pass


def crc32c(path: Path) -> str:
    """Return the GCS-compatible base64 big-endian CRC32C digest."""
    polynomial = 0x82F63B78
    value = 0xFFFFFFFF
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            for byte in chunk:
                value ^= byte
                for _ in range(8):
                    value = (value >> 1) ^ (polynomial if value & 1 else 0)
    return base64.b64encode(((value ^ 0xFFFFFFFF) & 0xFFFFFFFF).to_bytes(4, "big")).decode()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_name(name: str) -> str:
    posix = PurePosixPath(name)
    if any(ord(character) < 32 for character in name) or posix.is_absolute() or ".." in posix.parts or str(posix) in {"", "."}:
        raise ManifestError(f"unsafe object path: {name}")
    return str(posix)


def build(root: Path) -> dict[str, Any]:
    if not root.is_dir():
        raise ManifestError("snapshot root is missing")
    objects: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ManifestError(f"symlink is forbidden: {path}")
        if path.is_file():
            name = safe_name(path.relative_to(root).as_posix())
            objects.append(
                {
                    "name": name,
                    "size": path.stat().st_size,
                    "sha256": digest(path),
                    "crc32c": crc32c(path),
                }
            )
    if not objects:
        raise ManifestError("snapshot has no objects")
    canonical = json.dumps(objects, sort_keys=True, separators=(",", ":")).encode()
    snapshot_id = hashlib.sha256(canonical).hexdigest()
    return {"schema": "gcp-snapshot-manifest-v1", "snapshot_id": snapshot_id, "objects": objects}


def validate(manifest: dict[str, Any], root: Path | None = None, remote: Iterable[dict[str, Any]] | None = None) -> None:
    if manifest.get("schema") != "gcp-snapshot-manifest-v1" or not isinstance(manifest.get("objects"), list):
        raise ManifestError("manifest schema is invalid")
    names: set[str] = set()
    for item in manifest["objects"]:
        if not isinstance(item, dict):
            raise ManifestError("manifest object is invalid")
        name = safe_name(str(item.get("name", "")))
        if name in names:
            raise ManifestError(f"duplicate object: {name}")
        names.add(name)
        if not isinstance(item.get("size"), int) or item["size"] < 0:
            raise ManifestError(f"invalid size: {name}")
        if not isinstance(item.get("sha256"), str) or len(item["sha256"]) != 64:
            raise ManifestError(f"invalid digest: {name}")
        if not isinstance(item.get("crc32c"), str) or not item["crc32c"]:
            raise ManifestError(f"invalid CRC32C: {name}")
        if root is not None:
            path = root / name
            if not path.is_file() or path.is_symlink():
                raise ManifestError(f"missing or unsafe local object: {name}")
            if path.stat().st_size != item["size"] or digest(path) != item["sha256"] or crc32c(path) != item["crc32c"]:
                raise ManifestError(f"modified local object: {name}")
    canonical = json.dumps(manifest["objects"], sort_keys=True, separators=(",", ":")).encode()
    expected_snapshot_id = hashlib.sha256(canonical).hexdigest()
    if manifest.get("snapshot_id") != expected_snapshot_id:
        raise ManifestError("snapshot ID does not match the canonical object manifest")
    if remote is not None:
        remote_items = list(remote)
        remote_map = {safe_name(str(item["name"])): item for item in remote_items}
        if len(remote_map) != len(remote_items):
            raise ManifestError("remote snapshot contains duplicate objects")
        if set(remote_map) != names:
            raise ManifestError("remote snapshot is partial or contains unexpected objects")
        for item in manifest["objects"]:
            observed = remote_map[item["name"]]
            if (
                observed.get("size") != item["size"]
                or observed.get("sha256") != item["sha256"]
                or observed.get("crc32c") != item["crc32c"]
            ):
                raise ManifestError(f"remote object mismatch: {item['name']}")


def validate_commit(commit: dict[str, Any], manifest: dict[str, Any], manifest_bytes: bytes) -> None:
    if commit.get("schema") != "gcp-snapshot-commit-v1":
        raise ManifestError("commit marker schema is invalid")
    if commit.get("snapshot_id") != manifest.get("snapshot_id"):
        raise ManifestError("commit marker snapshot ID mismatch")
    if commit.get("manifest_sha256") != hashlib.sha256(manifest_bytes).hexdigest():
        raise ManifestError("commit marker manifest digest mismatch")
    objects = manifest.get("objects") or []
    if commit.get("object_count") != len(objects):
        raise ManifestError("commit marker object count mismatch")
    if commit.get("total_bytes") != sum(item.get("size", -1) for item in objects):
        raise ManifestError("commit marker byte count mismatch")


def write_new(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, sort_keys=True, indent=2)
        handle.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("build", "verify"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--commit", type=Path, help="required by consumers to verify snapshot visibility")
    args = parser.parse_args()
    try:
        if args.command == "build":
            manifest = build(args.root)
            write_new(args.manifest, manifest)
            print(manifest["snapshot_id"])
        else:
            manifest_bytes = args.manifest.read_bytes()
            manifest = json.loads(manifest_bytes)
            validate(manifest, args.root)
            if args.commit is not None:
                validate_commit(json.loads(args.commit.read_text()), manifest, manifest_bytes)
            print("snapshot manifest accepted")
    except (OSError, json.JSONDecodeError, ManifestError) as exc:
        print(f"snapshot-manifest: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
