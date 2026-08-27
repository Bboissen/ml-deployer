#!/usr/bin/env python3
"""Provider-neutral OCI acceptance workload using temporary cloud identity."""

from __future__ import annotations

import hashlib
import importlib.metadata
import io
import json
import os
import re
import sys
import tempfile
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import boto3
import duckdb
import numpy as np
import pandas as pd
import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq
import scipy
import statsmodels.api as sm
import xgboost
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobClient, BlobServiceClient, ContentSettings
from google.cloud import storage
from sklearn.linear_model import LinearRegression
from sklearn.metrics import root_mean_squared_error
from xgboost import XGBRegressor


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
DEPLOYMENT_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$")
UUID_PATTERN = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RUN_SPEC_KEYS = {"features", "rows", "schema_version", "seed", "workload"}
PACKAGE_NAMES = (
    "azure-identity",
    "azure-storage-blob",
    "boto3",
    "duckdb",
    "google-cloud-storage",
    "numpy",
    "pandas",
    "polars",
    "pyarrow",
    "scikit-learn",
    "scipy",
    "statsmodels",
    "xgboost-cpu",
)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def package_versions() -> dict[str, str]:
    return {name: importlib.metadata.version(name) for name in PACKAGE_NAMES}


@dataclass(frozen=True)
class RuntimeConfig:
    deployment_id: str
    provider: str
    run_spec_uri: str
    run_spec_sha256: str
    run_spec_object_version: str
    data_uri: str
    results_uri: str
    oci_digest: str

    @classmethod
    def from_environment(cls) -> "RuntimeConfig":
        required = (
            "ML_DEPLOYMENT_ID",
            "ML_CLOUD_PROVIDER",
            "ML_RUN_SPEC_URI",
            "ML_RUN_SPEC_SHA256",
            "ML_RUN_SPEC_OBJECT_VERSION",
            "ML_DATA_URI",
            "ML_RESULTS_URI",
            "ML_OCI_DIGEST",
        )
        values = {name: os.environ.get(name, "") for name in required}
        missing = [name for name, value in values.items() if not value]
        if missing:
            raise ValueError(f"missing environment: {','.join(missing)}")

        config = cls(
            deployment_id=values["ML_DEPLOYMENT_ID"],
            provider=values["ML_CLOUD_PROVIDER"],
            run_spec_uri=values["ML_RUN_SPEC_URI"],
            run_spec_sha256=values["ML_RUN_SPEC_SHA256"],
            run_spec_object_version=values["ML_RUN_SPEC_OBJECT_VERSION"],
            data_uri=values["ML_DATA_URI"],
            results_uri=values["ML_RESULTS_URI"],
            oci_digest=values["ML_OCI_DIGEST"],
        )
        config.validate()
        return config

    def validate(self) -> None:
        if not DEPLOYMENT_PATTERN.fullmatch(self.deployment_id):
            raise ValueError("invalid deployment ID")
        if self.provider not in {"aws", "gcp", "azure"}:
            raise ValueError("unsupported provider")
        if not SHA256_PATTERN.fullmatch(self.run_spec_sha256):
            raise ValueError("invalid run-spec SHA-256")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", self.oci_digest):
            raise ValueError("invalid OCI digest")
        expected_suffix = f"/run-specs/{self.deployment_id}/{self.run_spec_sha256}.json"
        if not self.run_spec_uri.endswith(expected_suffix):
            raise ValueError("run-spec URI is not bound to deployment and checksum")
        expected_results_suffix = f"/runs/{self.deployment_id}/results/"
        if not self.results_uri.endswith(expected_results_suffix):
            raise ValueError("results URI is not bound to deployment")


@dataclass(frozen=True)
class RunSpec:
    rows: int
    features: int
    seed: int

    @classmethod
    def from_bytes(cls, payload: bytes) -> "RunSpec":
        document = json.loads(payload)
        if not isinstance(document, dict) or set(document) != RUN_SPEC_KEYS:
            raise ValueError("run specification must contain the exact accepted fields")
        if document["schema_version"] != "1.0.0" or document["workload"] != "ml-stack-conformance":
            raise ValueError("unsupported conformance run specification")
        if type(document["rows"]) is not int or not 64 <= document["rows"] <= 4096:
            raise ValueError("rows must be an integer from 64 through 4096")
        if type(document["features"]) is not int or not 2 <= document["features"] <= 32:
            raise ValueError("features must be an integer from 2 through 32")
        if type(document["seed"]) is not int or not 0 <= document["seed"] <= 2**32 - 1:
            raise ValueError("seed must be an unsigned 32-bit integer")
        return cls(rows=document["rows"], features=document["features"], seed=document["seed"])


class ObjectStore(ABC):
    @abstractmethod
    def read_version(self, uri: str, object_version: str) -> bytes:
        raise NotImplementedError

    @abstractmethod
    def probe_prefix(self, uri: str) -> None:
        raise NotImplementedError

    @abstractmethod
    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        raise NotImplementedError


def bucket_and_key(uri: str, scheme: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != scheme or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError(f"invalid {scheme} object URI")
    return parsed.netloc, parsed.path.lstrip("/")


class S3ObjectStore(ObjectStore):
    def __init__(self) -> None:
        self.client = boto3.client("s3")

    def read_version(self, uri: str, object_version: str) -> bytes:
        bucket, key = bucket_and_key(uri, "s3")
        response = self.client.get_object(Bucket=bucket, Key=key, VersionId=object_version)
        return response["Body"].read()

    def probe_prefix(self, uri: str) -> None:
        bucket, prefix = bucket_and_key(uri, "s3")
        self.client.list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=1)

    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        bucket, key = bucket_and_key(uri, "s3")
        self.client.put_object(
            Bucket=bucket,
            Key=key,
            Body=payload,
            ContentType=content_type,
            IfNoneMatch="*",
        )


class GcsObjectStore(ObjectStore):
    def __init__(self) -> None:
        self.client = storage.Client()

    def read_version(self, uri: str, object_version: str) -> bytes:
        bucket, key = bucket_and_key(uri, "gs")
        generation = int(object_version)
        blob = self.client.bucket(bucket).blob(key, generation=generation)
        return blob.download_as_bytes(if_generation_match=generation)

    def probe_prefix(self, uri: str) -> None:
        bucket, prefix = bucket_and_key(uri, "gs")
        next(iter(self.client.list_blobs(bucket, prefix=prefix, max_results=1)), None)

    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        bucket, key = bucket_and_key(uri, "gs")
        self.client.bucket(bucket).blob(key).upload_from_string(
            payload,
            content_type=content_type,
            if_generation_match=0,
        )


def azure_parts(uri: str) -> tuple[str, str, str]:
    parsed = urlparse(uri)
    match = re.fullmatch(r"([a-z0-9]{3,24})\.blob\.core\.windows\.net", parsed.netloc)
    path_parts = parsed.path.lstrip("/").split("/", 1)
    if parsed.scheme != "https" or match is None or not path_parts[0] or parsed.query or parsed.fragment:
        raise ValueError("invalid Azure Blob URI")
    blob_name = path_parts[1] if len(path_parts) == 2 else ""
    return match.group(1), path_parts[0], blob_name


class AzureObjectStore(ObjectStore):
    def __init__(self) -> None:
        client_id = os.environ.get("ML_WORKLOAD_IDENTITY_CLIENT_ID", "")
        if not UUID_PATTERN.fullmatch(client_id):
            raise ValueError("Azure workload identity client ID is missing or invalid")
        self.credential = ManagedIdentityCredential(client_id=client_id)

    def read_version(self, uri: str, object_version: str) -> bytes:
        account, container, blob_name = azure_parts(uri)
        blob = BlobClient(
            account_url=f"https://{account}.blob.core.windows.net",
            container_name=container,
            blob_name=blob_name,
            credential=self.credential,
            version_id=object_version,
        )
        return blob.download_blob().readall()

    def probe_prefix(self, uri: str) -> None:
        account, container, prefix = azure_parts(uri)
        service = BlobServiceClient(
            account_url=f"https://{account}.blob.core.windows.net",
            credential=self.credential,
        )
        next(iter(service.get_container_client(container).list_blobs(name_starts_with=prefix, results_per_page=1)), None)

    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        account, container, blob_name = azure_parts(uri)
        blob = BlobClient(
            account_url=f"https://{account}.blob.core.windows.net",
            container_name=container,
            blob_name=blob_name,
            credential=self.credential,
        )
        blob.upload_blob(
            payload,
            overwrite=False,
            content_settings=ContentSettings(content_type=content_type),
        )


def object_store(provider: str) -> ObjectStore:
    return {"aws": S3ObjectStore, "gcp": GcsObjectStore, "azure": AzureObjectStore}[provider]()


@dataclass(frozen=True)
class Artifact:
    path: str
    content_type: str
    payload: bytes

    def manifest_entry(self) -> dict[str, Any]:
        return {
            "bytes": len(self.payload),
            "content_type": self.content_type,
            "path": self.path,
            "sha256": sha256(self.payload),
        }


class ConformanceWorkload:
    def __init__(self, run_spec: RunSpec, run_spec_sha256: str) -> None:
        self.run_spec = run_spec
        self.run_spec_sha256 = run_spec_sha256

    def execute(self) -> tuple[list[Artifact], bytes]:
        rng = np.random.default_rng(self.run_spec.seed)
        matrix = rng.normal(size=(self.run_spec.rows, self.run_spec.features))
        coefficients = np.arange(1, self.run_spec.features + 1, dtype=float)
        target = matrix @ coefficients + rng.normal(scale=0.05, size=self.run_spec.rows)
        columns = [f"feature_{index}" for index in range(self.run_spec.features)]
        frame = pd.DataFrame(matrix, columns=columns).assign(target=target)

        linear_model = LinearRegression().fit(matrix, target)
        linear_prediction = linear_model.predict(matrix)
        xgb_model = XGBRegressor(
            objective="reg:squarederror",
            n_estimators=8,
            max_depth=2,
            learning_rate=0.2,
            n_jobs=1,
            random_state=self.run_spec.seed,
            tree_method="hist",
            device="cpu",
            verbosity=0,
        ).fit(matrix, target)
        xgb_prediction = xgb_model.predict(matrix)
        ols = sm.OLS(target, sm.add_constant(matrix)).fit()
        correlation = scipy.stats.pearsonr(frame["feature_0"], frame["target"]).statistic

        parquet_buffer = io.BytesIO()
        pq.write_table(
            pa.Table.from_pandas(frame, preserve_index=False),
            parquet_buffer,
            compression="zstd",
            version="2.6",
        )
        parquet_payload = parquet_buffer.getvalue()

        with tempfile.TemporaryDirectory(prefix="ml-conformance-") as directory:
            parquet_path = Path(directory) / "conformance.parquet"
            parquet_path.write_bytes(parquet_payload)
            with duckdb.connect() as connection:
                duckdb_row = connection.execute(
                    "SELECT count(*)::BIGINT, avg(target)::DOUBLE FROM read_parquet(?)",
                    [str(parquet_path)],
                ).fetchone()
        polars_frame = pl.read_parquet(io.BytesIO(parquet_payload))

        summary = {
            "features": self.run_spec.features,
            "metrics": {
                "duckdb_target_mean": round(float(duckdb_row[1]), 12),
                "feature_0_target_correlation": round(float(correlation), 12),
                "linear_rmse": round(float(root_mean_squared_error(target, linear_prediction)), 12),
                "ols_r_squared": round(float(ols.rsquared), 12),
                "xgboost_rmse": round(float(root_mean_squared_error(target, xgb_prediction)), 12),
            },
            "package_versions": package_versions(),
            "parquet_rows": int(polars_frame.height),
            "rows": self.run_spec.rows,
            "run_spec_sha256": self.run_spec_sha256,
            "schema_version": "1.0.0",
            "workload": "ml-stack-conformance",
        }
        summary_payload = canonical_json(summary)
        artifacts = [
            Artifact("conformance.parquet", "application/vnd.apache.parquet", parquet_payload),
            Artifact("summary.json", "application/json", summary_payload),
        ]
        manifest = {
            "artifacts": [artifact.manifest_entry() for artifact in artifacts],
            "run_spec_sha256": self.run_spec_sha256,
            "schema_version": "1.0.0",
            "workload": "ml-stack-conformance",
        }
        return artifacts, canonical_json(manifest)


def run() -> None:
    config = RuntimeConfig.from_environment()
    store = object_store(config.provider)
    store.probe_prefix(config.data_uri)
    run_spec_payload = store.read_version(config.run_spec_uri, config.run_spec_object_version)
    actual_run_spec_sha256 = sha256(run_spec_payload)
    if actual_run_spec_sha256 != config.run_spec_sha256:
        raise ValueError("downloaded run-spec SHA-256 does not match the request")

    workload = ConformanceWorkload(RunSpec.from_bytes(run_spec_payload), config.run_spec_sha256)
    artifacts, manifest_payload = workload.execute()
    for artifact in artifacts:
        store.create(f"{config.results_uri}{artifact.path}", artifact.payload, artifact.content_type)
    store.create(f"{config.results_uri}result-manifest.json", manifest_payload, "application/json")

    print(
        canonical_json(
            {
                "deployment_id": config.deployment_id,
                "manifest_sha256": sha256(manifest_payload),
                "provider": config.provider,
                "status": "succeeded",
            }
        ).decode("ascii")
    )


def main() -> int:
    if sys.argv == [sys.argv[0], "--validate-install"]:
        print(canonical_json({"package_versions": package_versions(), "status": "install-valid"}).decode("ascii"))
        return 0
    if len(sys.argv) != 1:
        print("conformance: positional arguments are not accepted", file=sys.stderr)
        return 64
    try:
        run()
    except Exception as error:
        print(f"conformance: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
