"""Deterministic Phase 2 smoke-pack and worker-cache protocol.

Live callers must supply trusted pack and manifest hashes out of band.  Signed
plans are transport hints, never authorities for cache identity or integrity.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import math
import os
import random
import re
import shutil
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Mapping

PROTOCOL = "demo-smoke-pack-v1"
BUILDER = "spotify-ray-infra/storage_protocol.py"
PINNED_PYARROW = "24.0.0"
FULL_BYTES = 536_870_912
FULL_PARTITIONS = 16
MANIFEST_NAME = "manifest.json"
READY_NAME = ".ready"


class ProtocolError(RuntimeError):
    """A sanitized, non-secret-bearing protocol failure."""


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path, chunk: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(chunk):
            digest.update(block)
    return digest.hexdigest()


def _validate_sha256(value: str, label: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ProtocolError(f"{label} is not a lowercase SHA-256")


def _validate_bucket(bucket: str) -> None:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", bucket):
        raise ProtocolError("Bronze bucket name is invalid for exact virtual-hosted HTTPS")


def _safe_logical_path(raw: str) -> PurePosixPath:
    path = PurePosixPath(raw)
    if not raw or path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ProtocolError("manifest contains an unsafe object path")
    if str(path) != raw or any(not part for part in path.parts):
        raise ProtocolError("manifest contains a non-canonical object path")
    return path


def _descriptor(objects: list[dict[str, object]]) -> dict[str, object]:
    return {
        "builder": BUILDER,
        "objects": objects,
        "protocol": PROTOCOL,
        "pyarrow_version": PINNED_PYARROW,
    }


def build_pack(root: Path, profile: str = "full") -> dict[str, object]:
    """Build a byte-reproducible Parquet pack under an empty directory."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    if pa.__version__ != PINNED_PYARROW:
        raise ProtocolError(f"pack builder requires pyarrow=={PINNED_PYARROW}")
    if root.exists() and any(root.iterdir()):
        raise ProtocolError("pack output directory must be empty")
    root.mkdir(parents=True, exist_ok=True)
    if profile == "full":
        target, partitions = FULL_BYTES, FULL_PARTITIONS
    elif profile == "tiny":
        target, partitions = 262_144, 2
    else:
        raise ProtocolError("unknown pack profile")

    payload_width = 64
    rows = max(1, target // partitions // payload_width)
    objects: list[dict[str, object]] = []
    for index in range(partitions):
        logical = f"partition={index:02d}/part-00000.parquet"
        path = root / logical
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = random.Random(0xB0B1_0000 + index).randbytes(rows * payload_width)
        values = pa.Array.from_buffers(pa.binary(payload_width), rows, [None, pa.py_buffer(payload)])
        table = pa.Table.from_arrays([values], names=["payload"])
        pq.write_table(
            table,
            path,
            compression="NONE",
            use_dictionary=False,
            write_statistics=False,
            data_page_version="1.0",
            row_group_size=65_536,
        )
        del table, values, payload
        objects.append({"path": logical, "sha256": sha256_file(path), "size": path.stat().st_size})

    descriptor = _descriptor(objects)
    pack_hash = sha256_bytes(canonical_json(descriptor))
    manifest = {**descriptor, "prefix": f"smoke/{pack_hash}/", "test_pack_hash": pack_hash}
    manifest_bytes = canonical_json(manifest)
    (root / MANIFEST_NAME).write_bytes(manifest_bytes)
    if profile == "full":
        total = sum(int(item["size"]) for item in objects)
        if abs(total - FULL_BYTES) > FULL_BYTES * 0.01:
            raise ProtocolError("full pack is outside the one-percent size tolerance")
        if len(objects) != FULL_PARTITIONS:
            raise ProtocolError("full pack must contain exactly 16 objects")
    return {
        "manifest": manifest,
        "manifest_sha256": sha256_bytes(manifest_bytes),
        "test_pack_hash": pack_hash,
    }


def parse_manifest(raw: bytes, expected_pack_hash: str, expected_manifest_sha256: str) -> dict[str, object]:
    _validate_sha256(expected_pack_hash, "trusted pack hash")
    _validate_sha256(expected_manifest_sha256, "trusted manifest hash")
    if sha256_bytes(raw) != expected_manifest_sha256:
        raise ProtocolError("manifest SHA-256 does not match trusted expectation")
    try:
        manifest = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("manifest is not valid UTF-8 JSON") from exc
    if canonical_json(manifest) != raw:
        raise ProtocolError("manifest is not canonical JSON")
    required = {"builder", "objects", "prefix", "protocol", "pyarrow_version", "test_pack_hash"}
    if not isinstance(manifest, dict) or set(manifest) != required:
        raise ProtocolError("manifest schema is invalid")
    objects = manifest["objects"]
    if not isinstance(objects, list) or not objects:
        raise ProtocolError("manifest objects must be a non-empty list")
    seen: set[str] = set()
    for item in objects:
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "size"}:
            raise ProtocolError("manifest object schema is invalid")
        path = str(item["path"])
        _safe_logical_path(path)
        if path in seen:
            raise ProtocolError("manifest contains duplicate object paths")
        seen.add(path)
        if not isinstance(item["size"], int) or item["size"] < 0:
            raise ProtocolError("manifest object size is invalid")
        _validate_sha256(item["sha256"], "manifest object hash")
    descriptor = _descriptor(objects)
    calculated = sha256_bytes(canonical_json(descriptor))
    if calculated != expected_pack_hash or manifest["test_pack_hash"] != calculated:
        raise ProtocolError("pack hash does not match trusted expectation")
    if manifest["prefix"] != f"smoke/{calculated}/":
        raise ProtocolError("manifest prefix is invalid")
    if manifest["protocol"] != PROTOCOL or manifest["builder"] != BUILDER:
        raise ProtocolError("manifest protocol identity is invalid")
    if manifest["pyarrow_version"] != PINNED_PYARROW:
        raise ProtocolError("manifest PyArrow version is invalid")
    return manifest


def verify_pack(root: Path, expected_pack_hash: str, expected_manifest_sha256: str) -> dict[str, object]:
    if root.is_symlink() or not root.is_dir():
        raise ProtocolError("cache entry is not a real directory")
    manifest_path = root / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ProtocolError("manifest is missing or is a symlink")
    manifest = parse_manifest(manifest_path.read_bytes(), expected_pack_hash, expected_manifest_sha256)
    allowed = {MANIFEST_NAME, READY_NAME}
    allowed_dirs: set[str] = set()
    for item in manifest["objects"]:  # type: ignore[index]
        logical = str(item["path"])
        allowed.add(logical)
        parent = PurePosixPath(logical).parent
        while str(parent) != ".":
            allowed_dirs.add(str(parent))
            parent = parent.parent
        path = root / logical
        if path.is_symlink() or not path.is_file():
            raise ProtocolError("cache object is missing or is a symlink")
        if path.stat().st_size != item["size"] or sha256_file(path) != item["sha256"]:
            raise ProtocolError("cache object failed size or SHA-256 verification")
    actual = {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual - allowed:
        raise ProtocolError("cache entry contains unexpected files")
    actual_dirs = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_dir() and not path.is_symlink()}
    if actual_dirs != allowed_dirs:
        raise ProtocolError("cache entry contains unexpected or missing directories")
    ready_path = root / READY_NAME
    if ready_path.exists():
        if ready_path.is_symlink() or canonical_json(json.loads(ready_path.read_bytes())) != ready_path.read_bytes():
            raise ProtocolError("ready marker is invalid")
        ready = json.loads(ready_path.read_bytes())
        expected = {"manifest_sha256": expected_manifest_sha256, "protocol": PROTOCOL, "test_pack_hash": expected_pack_hash}
        if ready != expected:
            raise ProtocolError("ready marker does not bind trusted hashes")
    return manifest


def required_disk(snapshot_bytes: int, largest_object: int, workspace_bytes: int) -> int:
    if min(snapshot_bytes, largest_object, workspace_bytes) < 0:
        raise ProtocolError("disk inputs cannot be negative")
    return math.ceil(1.2 * (snapshot_bytes + largest_object + workspace_bytes))


@contextlib.contextmanager
def _locked(path: Path, blocking: bool = True) -> Iterator[object]:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+b")
    try:
        flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
        fcntl.flock(handle.fileno(), flags)
        yield handle
    finally:
        handle.close()


Fetch = Callable[[str, Path, int], None]


def _fsync_tree(root: Path) -> None:
    for path in root.rglob("*"):
        if path.is_file():
            with path.open("rb") as handle:
                os.fsync(handle.fileno())
    directories = [path for path in root.rglob("*") if path.is_dir() and not path.is_symlink()]
    for path in sorted(directories, key=lambda value: len(value.parts), reverse=True) + [root]:
        directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


def _atomic_bytes(path: Path, value: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def write_private_json(path: Path, value: object) -> None:
    _atomic_bytes(path, canonical_json(value), 0o600)


def validate_signed_url(url: str, bucket: str, logical_path: str) -> None:
    _validate_bucket(bucket)
    expected_host = f"{bucket}.ams3.digitaloceanspaces.com"
    parsed = urllib.parse.urlsplit(url)
    expected_path = "/" + urllib.parse.quote(logical_path, safe="/")
    if (
        parsed.scheme != "https"
        or parsed.hostname != expected_host
        or parsed.netloc != expected_host
        or parsed.path != expected_path
        or parsed.username is not None
        or parsed.fragment
        or not parsed.query
    ):
        raise ProtocolError("signed download URL violates endpoint policy")


def make_download_plan(
    bucket: str,
    manifest: Mapping[str, object],
    manifest_sha256: str,
    expires_at: int,
    signer: Callable[[str], str],
) -> dict[str, object]:
    now = int(time.time())
    if expires_at <= now or expires_at - now > 900:
        raise ProtocolError("signed plan expiry must be within 15 minutes")
    prefix = str(manifest["prefix"])
    paths = [MANIFEST_NAME] + [str(item["path"]) for item in manifest["objects"]]  # type: ignore[index]
    downloads = []
    for path in paths:
        key = prefix + path
        url = signer(key)
        validate_signed_url(url, bucket, key)
        downloads.append({"path": path, "url": url})
    return {
        "bucket": bucket,
        "expires_at": expires_at,
        "manifest_sha256": manifest_sha256,
        "prefix": prefix,
        "protocol": PROTOCOL,
        "test_pack_hash": manifest["test_pack_hash"],
        "downloads": downloads,
    }


def presign_get_plan(client, bucket: str, manifest: Mapping[str, object], manifest_sha256: str, expires_in: int = 300) -> dict[str, object]:
    if expires_in <= 0 or expires_in > 900:
        raise ProtocolError("presigned GET lifetime must be between 1 and 900 seconds")
    return make_download_plan(
        bucket,
        manifest,
        manifest_sha256,
        int(time.time()) + expires_in,
        lambda key: client.generate_presigned_url(
            "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=expires_in, HttpMethod="GET"
        ),
    )


def boto3_bronze_client(environ: Mapping[str, str] | None = None):
    environment = os.environ if environ is None else environ
    access_key = environment.get("BRONZE_SPACES_ACCESS_KEY_ID", "")
    secret_key = environment.get("BRONZE_SPACES_SECRET_ACCESS_KEY", "")
    if not access_key or not secret_key:
        raise ProtocolError("dedicated Bronze credentials are required")
    try:
        import boto3
        from botocore.config import Config
    except ImportError as exc:
        raise ProtocolError("boto3 is not installed") from exc
    return boto3.client(
        "s3",
        endpoint_url="https://ams3.digitaloceanspaces.com",
        region_name="us-east-1",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 2, "mode": "standard"},
            s3={"addressing_style": "virtual"},
        ),
    )


def publish_and_verify(
    client,
    bucket: str,
    root: Path,
    expected_pack_hash: str,
    expected_manifest_sha256: str,
) -> None:
    """Upload exact members, then HEAD/list verify membership, bytes and hash metadata."""
    _validate_bucket(bucket)
    if root.is_symlink() or not root.is_dir() or (root / READY_NAME).exists():
        raise ProtocolError("publication root is not an exact pack directory")
    manifest_path = root / MANIFEST_NAME
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ProtocolError("publication manifest is missing or is a symlink")
    manifest_raw = manifest_path.read_bytes()
    manifest = parse_manifest(manifest_raw, expected_pack_hash, expected_manifest_sha256)
    verify_pack(root, expected_pack_hash, expected_manifest_sha256)
    prefix = str(manifest["prefix"])
    members = [{"path": MANIFEST_NAME, "size": (root / MANIFEST_NAME).stat().st_size, "sha256": sha256_file(root / MANIFEST_NAME)}]
    members.extend(manifest["objects"])  # type: ignore[arg-type]
    for item in members:
        path = str(item["path"])
        client.upload_file(
            str(root / path), bucket, prefix + path,
            ExtraArgs={"Metadata": {"sha256": str(item["sha256"])}, "ContentType": "application/octet-stream"},
        )
    listed: list[str] = []
    token = None
    while True:
        args = {"Bucket": bucket, "Prefix": prefix}
        if token:
            args["ContinuationToken"] = token
        response = client.list_objects_v2(**args)
        listed.extend(entry["Key"] for entry in response.get("Contents", []))
        if not response.get("IsTruncated"):
            break
        token = response["NextContinuationToken"]
    expected = {prefix + str(item["path"]) for item in members}
    if set(listed) != expected or len(listed) != len(expected):
        raise ProtocolError("published prefix membership verification failed")
    for item in members:
        head = client.head_object(Bucket=bucket, Key=prefix + str(item["path"]))
        if head.get("ContentLength") != item["size"] or head.get("Metadata", {}).get("sha256") != item["sha256"]:
            raise ProtocolError("published object HEAD verification failed")


@dataclass(frozen=True)
class CacheResult:
    path: Path
    reused: bool


def materialize_cache(
    cache_root: Path,
    plan: Mapping[str, object],
    expected_pack_hash: str,
    expected_manifest_sha256: str,
    workspace_bytes: int,
    cache_limit_bytes: int,
    fetch: Fetch,
    free_bytes: int | None = None,
) -> CacheResult:
    """Cold materialization; the injected fetcher is the only I/O transport."""
    _validate_sha256(expected_pack_hash, "trusted pack hash")
    _validate_sha256(expected_manifest_sha256, "trusted manifest hash")
    if plan.get("test_pack_hash") != expected_pack_hash or plan.get("manifest_sha256") != expected_manifest_sha256:
        raise ProtocolError("download plan does not bind trusted hashes")
    if plan.get("protocol") != PROTOCOL or plan.get("prefix") != f"smoke/{expected_pack_hash}/":
        raise ProtocolError("download plan protocol or prefix is invalid")
    if not isinstance(plan.get("expires_at"), int) or int(plan["expires_at"]) <= int(time.time()):
        raise ProtocolError("download plan has expired")
    bucket = plan.get("bucket")
    if not isinstance(bucket, str) or not bucket:
        raise ProtocolError("download plan bucket is invalid")
    cache_root.mkdir(parents=True, exist_ok=True)
    locks = cache_root / ".locks"
    target = cache_root / expected_pack_hash
    with _locked(cache_root / ".management.lock"):
        _remove_stale_partials(cache_root, 24 * 3600)
    with _locked(locks / f"{expected_pack_hash}.lock"):
        if target.exists():
            verify_pack(target, expected_pack_hash, expected_manifest_sha256)
            if not (target / READY_NAME).exists():
                raise ProtocolError("existing cache entry has no ready marker")
            return CacheResult(target, True)
        downloads = plan.get("downloads")
        if not isinstance(downloads, list):
            raise ProtocolError("download plan schema is invalid")
        by_path: dict[str, str] = {}
        for item in downloads:
            if not isinstance(item, dict) or set(item) != {"path", "url"}:
                raise ProtocolError("download plan item schema is invalid")
            logical, url = item["path"], item["url"]
            if not isinstance(logical, str) or not isinstance(url, str):
                raise ProtocolError("download plan item types are invalid")
            _safe_logical_path(logical)
            if logical in by_path:
                raise ProtocolError("download plan contains duplicate paths")
            by_path[logical] = url
        if set(by_path) != {MANIFEST_NAME} | {str(item["path"]) for item in plan.get("objects", [])}:  # optional expanded plan
            # The authoritative object set arrives in the manifest, so only require manifest now.
            if MANIFEST_NAME not in by_path:
                raise ProtocolError("download plan has no manifest")
        for logical, url in by_path.items():
            validate_signed_url(url, bucket, f"smoke/{expected_pack_hash}/{logical}")
        stage = cache_root / f".{expected_pack_hash}.partial.{os.getpid()}.{time.time_ns()}"
        stage.mkdir(mode=0o700)
        try:
            fetch(by_path[MANIFEST_NAME], stage / MANIFEST_NAME, 8 * 1024 * 1024)
            manifest = parse_manifest((stage / MANIFEST_NAME).read_bytes(), expected_pack_hash, expected_manifest_sha256)
            expected_paths = {MANIFEST_NAME} | {str(item["path"]) for item in manifest["objects"]}  # type: ignore[index]
            if set(by_path) != expected_paths:
                raise ProtocolError("download plan membership differs from manifest")
            snapshot = sum(int(item["size"]) for item in manifest["objects"])  # type: ignore[index]
            largest = max(int(item["size"]) for item in manifest["objects"])  # type: ignore[index]
            ready_bytes = len(canonical_json({
                "manifest_sha256": expected_manifest_sha256,
                "protocol": PROTOCOL,
                "test_pack_hash": expected_pack_hash,
            }))
            cache_bytes = snapshot + (stage / MANIFEST_NAME).stat().st_size + ready_bytes
            available = free_bytes if free_bytes is not None else shutil.disk_usage(cache_root).free
            needed = required_disk(snapshot, largest, workspace_bytes)
            if available < needed:
                raise ProtocolError("insufficient disk space for cache materialization")
            with _locked(cache_root / ".management.lock"):
                evict_cache(cache_root, cache_limit_bytes, cache_bytes, expected_pack_hash)
            for item in manifest["objects"]:  # type: ignore[index]
                logical = str(item["path"])
                destination = stage / logical
                destination.parent.mkdir(parents=True, exist_ok=True)
                fetch(by_path[logical], destination, int(item["size"]))
                if destination.is_symlink() or destination.stat().st_size != item["size"] or sha256_file(destination) != item["sha256"]:
                    raise ProtocolError("downloaded object failed size or SHA-256 verification")
            _atomic_bytes(stage / READY_NAME, canonical_json({
                "manifest_sha256": expected_manifest_sha256,
                "protocol": PROTOCOL,
                "test_pack_hash": expected_pack_hash,
            }))
            verify_pack(stage, expected_pack_hash, expected_manifest_sha256)
            _fsync_tree(stage)
            os.rename(stage, target)
            parent = os.open(cache_root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
            return CacheResult(target, False)
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def warm_verify(cache_root: Path, expected_pack_hash: str, expected_manifest_sha256: str) -> Path:
    """Network-free reuse path: accepts no plan, URL, fetcher, or credentials."""
    _validate_sha256(expected_pack_hash, "trusted pack hash")
    _validate_sha256(expected_manifest_sha256, "trusted manifest hash")
    target = cache_root / expected_pack_hash
    with _locked(cache_root / ".locks" / f"{expected_pack_hash}.lock"):
        verify_pack(target, expected_pack_hash, expected_manifest_sha256)
        if not (target / READY_NAME).exists():
            raise ProtocolError("warm cache has no ready marker")
    return target


def _remove_stale_partials(cache_root: Path, max_age_seconds: int) -> None:
    cutoff = time.time() - max_age_seconds
    for path in cache_root.glob(".*.partial.*"):
        if not path.is_dir() or path.is_symlink() or path.stat().st_mtime >= cutoff:
            continue
        match = re.fullmatch(r"\.([0-9a-f]{64})\.partial\..+", path.name)
        if not match:
            continue
        try:
            with _locked(cache_root / ".locks" / f"{match.group(1)}.lock", blocking=False):
                shutil.rmtree(path)
        except BlockingIOError:
            continue


def evict_cache(cache_root: Path, limit_bytes: int, incoming_bytes: int, current_hash: str) -> None:
    if limit_bytes <= 0 or incoming_bytes > limit_bytes:
        raise ProtocolError("cache size limit cannot accommodate incoming snapshot")
    entries: list[tuple[float, int, Path]] = []
    total = incoming_bytes
    for path in cache_root.iterdir():
        if path.name.startswith(".") or path.name == current_hash or not path.is_dir() or path.is_symlink():
            continue
        ready = path / READY_NAME
        if not ready.is_file() or ready.is_symlink():
            continue
        size = sum(item.stat().st_size for item in path.rglob("*") if item.is_file() and not item.is_symlink())
        total += size
        entries.append((ready.stat().st_mtime, size, path))
    for _, size, path in sorted(entries):
        if total <= limit_bytes:
            break
        try:
            with _locked(cache_root / ".locks" / f"{path.name}.lock", blocking=False):
                shutil.rmtree(path)
                total -= size
        except BlockingIOError:
            continue
    if total > limit_bytes:
        raise ProtocolError("cache limit cannot be met without removing locked entries")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        raise ProtocolError("download redirects are forbidden")


def https_fetch(url: str, destination: Path, max_bytes: int, timeout: float = 30.0) -> None:
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(url, timeout=timeout) as response, destination.open("xb") as handle:
            total = 0
            while block := response.read(min(1024 * 1024, max_bytes + 1 - total)):
                total += len(block)
                if total > max_bytes:
                    raise ProtocolError("download exceeded declared byte bound")
                handle.write(block)
            handle.flush()
            os.fsync(handle.fileno())
    except ProtocolError:
        raise
    except (OSError, urllib.error.URLError) as exc:
        raise ProtocolError(f"bounded HTTPS download failed ({type(exc).__name__})") from None
