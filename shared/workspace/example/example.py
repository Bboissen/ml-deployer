#!/usr/bin/env python3
"""Calculate and verify bounded, explicitly staged acceptance bytes."""
import argparse
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
EXPECTED = (ROOT / "expected.json").read_bytes()
FIXTURE_HASH = (ROOT / "SHA256SUMS").read_text().splitlines()[0].split()[0]


def bounded(path):
    with Path(path).open("rb") as stream:
        data = stream.read(129)
    if len(data) > 128:
        raise ValueError("staging: object exceeds 128 bytes")
    return data


def calculate(source, destination):
    if version("numpy") != "2.2.6" or version("pandas") != "2.2.3":
        raise ValueError("dependencies: locked NumPy/pandas versions required")
    import io
    import numpy as np
    import pandas as pd

    data = bounded(source)
    if hashlib.sha256(data).hexdigest() != FIXTURE_HASH:
        raise ValueError("download: fixture bytes/hash mismatch")
    values = pd.read_csv(io.BytesIO(data), dtype={"value": "int64"})["value"].to_numpy()
    result = {"count": int(values.size), "sum": int(np.sum(values)), "mean": float(np.mean(values))}
    encoded = (json.dumps(result, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    if result != {"count": 4, "sum": 10, "mean": 2.5} or encoded != EXPECTED:
        raise ValueError("calculation: known result mismatch")
    with Path(destination).open("xb") as stream:
        stream.write(encoded)


def verify(local, retrieved):
    if bounded(local) != EXPECTED or bounded(retrieved) != EXPECTED:
        raise ValueError("retrieve: result must match expected values and exact bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("calculate", "verify"))
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    if args.operation == "calculate":
        calculate(args.source, args.destination)
    else:
        verify(args.source, args.destination)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, ImportError) as error:
        print(f"acceptance example failed: {error}", file=sys.stderr)
        sys.exit(2)
