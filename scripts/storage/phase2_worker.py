#!/usr/bin/env python3
"""Worker-side Phase 2 cache and evidence commands."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from spotify_ray_infra.phase2_control import collect_worker_network_receipt, terminal_receipt
from spotify_ray_infra.storage_protocol import ProtocolError, https_fetch, materialize_cache, warm_verify


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    cold = commands.add_parser("cold")
    cold.add_argument("--plan", required=True, type=Path)
    for command in (cold, commands.add_parser("warm")):
        command.add_argument("--cache-root", type=Path, default=Path("/data/demo-cache"))
        command.add_argument("--pack-hash", required=True)
        command.add_argument("--manifest-hash", required=True)
        command.add_argument("--receipt", required=True, type=Path)
        command.add_argument("--run-id", required=True)
    cold.add_argument("--workspace-bytes", required=True, type=int)
    cold.add_argument("--cache-limit-bytes", required=True, type=int)
    network = commands.add_parser("network")
    for name in ("run-id", "bucket", "expected-vpc-uuid", "expected-vpc-cidr", "expected-droplet-id", "controller-vpc-uuid", "controller-droplet-id"):
        network.add_argument(f"--{name}", required=True)
    network.add_argument("--receipt", required=True, type=Path)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "network":
        collect_worker_network_receipt(
            args.receipt, args.run_id, args.bucket, args.expected_vpc_uuid,
            args.expected_vpc_cidr, args.expected_droplet_id,
            args.controller_vpc_uuid, args.controller_droplet_id,
        )
        return 0
    try:
        if args.command == "cold":
            if args.plan.stat().st_mode & 0o777 != 0o600:
                raise ProtocolError("signed plan must have mode 0600")
            plan = json.loads(args.plan.read_bytes())
            result = materialize_cache(
                args.cache_root, plan, args.pack_hash, args.manifest_hash,
                args.workspace_bytes, args.cache_limit_bytes, https_fetch,
            )
            detail = "reused" if result.reused else "materialized"
        else:
            # Warm intentionally accepts no plan, URL, or credential option.
            warm_verify(args.cache_root, args.pack_hash, args.manifest_hash)
            detail = "verified_without_plan"
        terminal_receipt(args.receipt, args.run_id, f"cache-{args.command}", "success", detail)
        return 0
    except Exception as exc:
        detail = str(exc) if isinstance(exc, ProtocolError) else f"unexpected_{type(exc).__name__}"
        terminal_receipt(args.receipt, args.run_id, f"cache-{args.command}", "error", detail)
        raise ProtocolError(detail) from None


if __name__ == "__main__":
    raise SystemExit(main())
