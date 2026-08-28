#!/usr/bin/env python3
"""Generate the reviewed deterministic synthetic Parquet fixture."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq


ROOT = Path(__file__).resolve().parent
FIXTURE_PATH = ROOT / "fixtures" / "synthetic-input.parquet"
CONTRACT_PATH = ROOT / "fixture-contract.json"


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def main() -> None:
    rows = 64
    row_id = list(range(rows))
    segment = ["a", "b", "c", "d"] * 16
    feature_a = [(index - 31.5) / 8.0 for index in row_id]
    feature_b = [(((index * 7) % 17) - 8) / 4.0 for index in row_id]
    feature_c = [((index % 5) - 2) / 2.0 for index in row_id]
    target = [
        1.25 * feature_a[index]
        - 0.5 * feature_b[index]
        + 0.75 * feature_c[index]
        + ((index % 3) - 1) * 0.125
        for index in row_id
    ]
    class_label = [int(value >= 0.0) for value in target]

    schema = pa.schema(
        [
            pa.field("row_id", pa.int64(), nullable=False),
            pa.field("segment", pa.string(), nullable=False),
            pa.field("feature_a", pa.float64(), nullable=False),
            pa.field("feature_b", pa.float64(), nullable=False),
            pa.field("feature_c", pa.float64(), nullable=False),
            pa.field("target", pa.float64(), nullable=False),
            pa.field("class_label", pa.int8(), nullable=False),
        ]
    )
    table = pa.Table.from_arrays(
        [row_id, segment, feature_a, feature_b, feature_c, target, class_label],
        schema=schema,
    )

    FIXTURE_PATH.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(
        table,
        FIXTURE_PATH,
        compression="NONE",
        data_page_version="1.0",
        use_dictionary=False,
        version="2.6",
        write_statistics=True,
    )
    payload = FIXTURE_PATH.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    segment_counts = {
        key.as_py(): value.as_py()
        for key, value in zip(
            pc.value_counts(table["segment"]).field("values"),
            pc.value_counts(table["segment"]).field("counts"),
            strict=True,
        )
    }
    contract = {
        "schema_version": "1.0.0",
        "fixture_kind": "synthetic-infrastructure-test-data",
        "object_key": f"fixtures/tool-complete-dummy/{digest}.parquet",
        "bytes": len(payload),
        "sha256": digest,
        "schema": [
            {"name": field.name, "type": str(field.type), "nullable": field.nullable}
            for field in schema
        ],
        "logical_results": {
            "row_count": rows,
            "row_id_min": min(row_id),
            "row_id_max": max(row_id),
            "class_positive_count": sum(class_label),
            "feature_a_sum": round(sum(feature_a), 12),
            "feature_b_sum": round(sum(feature_b), 12),
            "feature_c_sum": round(sum(feature_c), 12),
            "target_sum": round(sum(target), 12),
            "segment_counts": dict(sorted(segment_counts.items())),
        },
        "encoding": {
            "created_by": f"pyarrow-{pa.__version__}",
            "compression": "NONE",
            "data_page_version": "1.0",
            "dictionary_encoding": False,
            "parquet_version": "2.6",
        },
    }
    CONTRACT_PATH.write_bytes(canonical_json(contract))
    print(canonical_json(contract).decode().strip())


if __name__ == "__main__":
    main()
