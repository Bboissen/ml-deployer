from __future__ import annotations

import argparse
import os
import socket
from typing import Any

import psutil
import ray


@ray.remote
def probe() -> dict[str, Any]:
    return {
        "hostname": socket.gethostname(),
        "pid": os.getpid(),
        "cpu_count": psutil.cpu_count(logical=True),
        "memory_gb": round(psutil.virtual_memory().total / (1024**3), 2),
    }


def node_resource_key(node: dict[str, Any]) -> str | None:
    resources = node.get("Resources") or {}
    for key in resources:
        if key.startswith("node:") and key != "node:__internal_head__":
            return key
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-workers", type=int, default=0)
    parser.add_argument("--status-only", action="store_true")
    args = parser.parse_args()

    if not ray.is_initialized():
        ray.init(address="auto", ignore_reinit_error=True)

    nodes = [n for n in ray.nodes() if n.get("Alive")]
    worker_nodes = [n for n in nodes if "node:__internal_head__" not in (n.get("Resources") or {})]
    # Count non-head nodes heuristically. Ray resources include node IDs; exact head detection is not stable across versions.
    total_nodes = len(nodes)
    print(f"Alive Ray nodes: {total_nodes}")
    for n in nodes:
        print({"node_id": n.get("NodeID"), "node_ip": n.get("NodeManagerAddress"), "resources": n.get("Resources")})

    if args.expected_workers and total_nodes < args.expected_workers + 1:
        raise SystemExit(f"Expected at least {args.expected_workers + 1} total nodes including head, got {total_nodes}")
    if args.expected_workers and len(worker_nodes) < args.expected_workers:
        raise SystemExit(f"Expected at least {args.expected_workers} worker nodes, got {len(worker_nodes)}")

    if not args.status_only:
        refs = []
        if args.expected_workers:
            for node in worker_nodes[: args.expected_workers]:
                resource_key = node_resource_key(node)
                if resource_key is None:
                    raise SystemExit(f"Could not find node resource for worker {node.get('NodeManagerAddress')}")
                refs.append(probe.options(resources={resource_key: 0.001}).remote())
        else:
            refs = [probe.remote()]
        for result in ray.get(refs):
            print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
