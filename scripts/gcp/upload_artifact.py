#!/usr/bin/env python3
"""Create one immutable run artifact with a create-only GCS identity."""

from __future__ import annotations

import argparse
import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any

from snapshot_manifest import crc32c

PROJECT = "example-project"
BUCKET = f"{PROJECT}-artifacts"
TRAINER = f"training-runtime@{PROJECT}.iam.gserviceaccount.com"


class ArtifactError(ValueError):
    pass


def safe_object_name(name: str) -> str:
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or any(ord(character) < 32 for character in name):
        raise ArtifactError("artifact object name is unsafe")
    if len(path.parts) < 4 or path.parts[:2] != ("artifacts", "runs"):
        raise ArtifactError("artifact object must be under artifacts/runs/<run_id>/")
    return str(path)


def access_token(identity: str) -> str:
    completed = subprocess.run(
        ["gcloud", "auth", "print-access-token", f"--impersonate-service-account={identity}"],
        check=True,
        capture_output=True,
        text=True,
    )
    token = completed.stdout.strip()
    if not token:
        raise ArtifactError("gcloud returned an empty access token")
    return token


def upload(path: Path, object_name: str, identity: str = TRAINER) -> dict[str, Any]:
    if identity != TRAINER:
        raise ArtifactError(f"artifact identity must be exactly {TRAINER}")
    if not path.is_file() or path.is_symlink():
        raise ArtifactError("artifact source must be a regular file")
    object_name = safe_object_name(object_name)
    query = urllib.parse.urlencode({"uploadType": "media", "name": object_name, "ifGenerationMatch": "0"})
    request = urllib.request.Request(
        f"https://storage.googleapis.com/upload/storage/v1/b/{BUCKET}/o?{query}",
        data=path.read_bytes(),
        method="POST",
        headers={
            "Authorization": f"Bearer {access_token(identity)}",
            "Content-Type": "application/octet-stream",
            "Content-Length": str(path.stat().st_size),
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        observed = json.load(response)
    if int(observed.get("size", -1)) != path.stat().st_size or observed.get("crc32c") != crc32c(path):
        raise ArtifactError("GCS upload response failed size or CRC32C verification")
    return observed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true", help="required live-mutation gate")
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--object", required=True)
    parser.add_argument("--impersonate-service-account", required=True)
    args = parser.parse_args()
    if not args.execute:
        print("artifact-upload: refusing live upload without --execute")
        return 2
    try:
        observed = upload(args.file, args.object, args.impersonate_service_account)
        print(f"artifact-upload: created gs://{BUCKET}/{safe_object_name(args.object)} generation={observed['generation']}")
    except (OSError, KeyError, ArtifactError, subprocess.CalledProcessError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"artifact-upload: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
