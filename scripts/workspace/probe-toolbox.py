#!/usr/bin/env python3
"""Read-only local facts for provider readiness collectors; no authentication checks."""
import argparse
from importlib.metadata import PackageNotFoundError, version
from importlib.util import find_spec
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TOOLBOX = json.loads((ROOT / "shared/workspace/toolbox.json").read_text())


def probe(provider, directory):
    cli, *packages = TOOLBOX["provider_tools"][provider]
    versions = {"python": platform.python_version()}
    missing = []
    for tool in ("git", "uv", "cc", "make", cli):
        key = "storage_cli" if tool == cli else tool
        try:
            args = [tool, "version"] if tool == "gcloud" else [tool, "--version"]
            result = subprocess.run(args, check=True, capture_output=True, text=True, timeout=10)
            versions[key] = (result.stdout or result.stderr).splitlines()[0]
        except (OSError, subprocess.SubprocessError, IndexError):
            missing.append(tool)
    sdk_versions = {}
    for package in packages:
        try:
            sdk_versions[package] = version(package)
        except PackageNotFoundError:
            missing.append(package)
    path = Path(directory)
    exists = path.is_dir()
    return {
        "provider": provider, "versions": versions, "sdk_versions": sdk_versions,
        "missing_tools": missing, "os": platform.system(), "architecture": platform.machine(),
        "resources": {"cpus": os.cpu_count(),
                      "memory_mb": os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // (1024 ** 2),
                      "disk_gb": shutil.disk_usage(path).total // (1024 ** 3) if exists else 0},
        "non_root": os.geteuid() != 0,
        "project_directory_writable": exists and os.access(path, os.W_OK | os.X_OK),
        "python_supported": platform.python_version().startswith(TOOLBOX["python_minor"] + "."),
        "venv_available": find_spec("venv") is not None,
        "unverified_checks": ["terminal", "identity", "storage", "state_denied", "unrelated_denied", "deadline"],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=("aws", "gcp", "azure"))
    parser.add_argument("project_directory")
    args = parser.parse_args()
    facts = probe(args.provider, args.project_directory)
    print(json.dumps(facts, sort_keys=True))
    raise SystemExit(0 if not facts["missing_tools"] and facts["python_supported"]
                     and facts["non_root"] and facts["project_directory_writable"]
                     and facts["venv_available"] and facts["os"] == TOOLBOX["os"]
                     and facts["architecture"] == TOOLBOX["architecture"] else 2)
