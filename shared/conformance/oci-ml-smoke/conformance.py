#!/usr/bin/env python3
"""Bounded, provider-neutral, tool-complete dummy ML workload."""

from __future__ import annotations

import hashlib
import importlib
import importlib.metadata
import io
import json
import os
import re
import sys
import tempfile
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Literal
from urllib.parse import urlparse

import boto3
import duckdb
import mlflow
import numpy as np
import optuna
import pandas as pd
import pandera.pandas as pandera
import polars as pl
import pyarrow as arrow
import pyarrow.compute as arrow_compute
import pyarrow.parquet as parquet
import ray
import scipy
import shap
import statsmodels.api as sm
import typer
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobClient, ContentSettings
from catboost import CatBoostRegressor
from google.cloud import storage
from lightgbm import LGBMRegressor
from pydantic import BaseModel, ConfigDict, Field, model_validator
from ray import tune
from sklearn.calibration import calibration_curve
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.metrics import brier_score_loss, root_mean_squared_error
from xgboost import XGBRegressor


WORKLOAD_ROOT = Path(__file__).resolve().parent
PACKAGE_MATRIX_PATH = WORKLOAD_ROOT / "package-matrix.json"
PACKAGE_LOCK_PATH = WORKLOAD_ROOT / "requirements.lock"
EXPECTED_OUTPUT_PATH = WORKLOAD_ROOT / "expected-output.json"
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
DEPLOYMENT_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$")
UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
PROVIDER_SCHEMES = {"aws": "s3", "gcp": "gs", "azure": "https"}
RESULT_MANIFEST_PATH = "result-manifest.json"


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def load_json_file(path: Path) -> dict[str, Any]:
    document = json.loads(path.read_bytes())
    if not isinstance(document, dict):
        raise ValueError(f"{path.name} must contain one JSON object")
    return document


def package_versions(matrix_path: Path = PACKAGE_MATRIX_PATH) -> dict[str, str]:
    matrix = load_json_file(matrix_path)
    python_contract = matrix.get("python")
    packages = matrix.get("packages")
    if not isinstance(python_contract, dict) or not isinstance(packages, list):
        raise ValueError("package matrix shape is invalid")
    if python_contract.get("version") != ".".join(map(str, sys.version_info[:3])):
        raise ValueError("running Python does not match the frozen package matrix")

    versions: dict[str, str] = {}
    for package in packages:
        if not isinstance(package, dict):
            raise ValueError("package matrix contains a non-object package")
        distribution = package.get("distribution")
        expected_version = package.get("version")
        imports = package.get("imports")
        if not isinstance(distribution, str) or not isinstance(expected_version, str):
            raise ValueError("package matrix distribution/version is invalid")
        if not isinstance(imports, list) or not imports or not all(isinstance(name, str) for name in imports):
            raise ValueError(f"package matrix imports are invalid for {distribution}")
        actual_version = importlib.metadata.version(distribution)
        if actual_version != expected_version:
            raise ValueError(
                f"package version mismatch for {distribution}: expected {expected_version}, got {actual_version}"
            )
        for import_name in imports:
            importlib.import_module(import_name)
        versions[distribution] = actual_version
    return dict(sorted(versions.items()))


class SchemaField(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    name: str
    type: str
    nullable: bool


class LogicalResults(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    row_count: int
    row_id_min: int
    row_id_max: int
    class_positive_count: int
    feature_a_sum: float
    feature_b_sum: float
    feature_c_sum: float
    target_sum: float
    segment_counts: dict[str, int]


class InputSpec(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    object_key: str
    bytes: int = Field(ge=1, le=1_048_576)
    sha256: str
    schema_fields: list[SchemaField] = Field(alias="schema")
    logical_results: LogicalResults

    @model_validator(mode="after")
    def immutable_object_key(self) -> "InputSpec":
        if not SHA256_PATTERN.fullmatch(self.sha256):
            raise ValueError("input SHA-256 is invalid")
        expected = f"fixtures/tool-complete-dummy/{self.sha256}.parquet"
        if self.object_key != expected:
            raise ValueError("input object key must be content-addressed by its exact SHA-256")
        validate_relative_path(self.object_key)
        return self


class Limits(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    rows: Literal[64]
    optuna_trials: Literal[1]
    ray_trials: Literal[1]
    ray_cpus: Literal[1]


class RunSpec(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    schema_version: Literal["1.0.0"]
    workload: Literal["tool-complete-dummy"]
    seed: int = Field(ge=0, le=2**32 - 1)
    input: InputSpec
    limits: Limits
    expected_output_policy_sha256: str

    @model_validator(mode="after")
    def closed_bindings(self) -> "RunSpec":
        if self.limits.rows != self.input.logical_results.row_count:
            raise ValueError("run row limit does not match the frozen input")
        if not SHA256_PATTERN.fullmatch(self.expected_output_policy_sha256):
            raise ValueError("expected-output policy SHA-256 is invalid")
        return self

    @classmethod
    def from_bytes(cls, payload: bytes) -> "RunSpec":
        return cls.model_validate_json(payload, strict=True)


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
    maximum_runtime_minutes: int
    local_object_root: str | None = None

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
            "ML_MAX_RUNTIME_MINUTES",
        )
        values = {name: os.environ.get(name, "") for name in required}
        missing = [name for name, value in values.items() if not value]
        if missing:
            raise ValueError(f"missing environment: {','.join(missing)}")
        try:
            maximum_runtime_minutes = int(values["ML_MAX_RUNTIME_MINUTES"])
        except ValueError as error:
            raise ValueError("maximum runtime must be an integer") from error
        config = cls(
            deployment_id=values["ML_DEPLOYMENT_ID"],
            provider=values["ML_CLOUD_PROVIDER"],
            run_spec_uri=values["ML_RUN_SPEC_URI"],
            run_spec_sha256=values["ML_RUN_SPEC_SHA256"],
            run_spec_object_version=values["ML_RUN_SPEC_OBJECT_VERSION"],
            data_uri=values["ML_DATA_URI"],
            results_uri=values["ML_RESULTS_URI"],
            oci_digest=values["ML_OCI_DIGEST"],
            maximum_runtime_minutes=maximum_runtime_minutes,
            local_object_root=os.environ.get("ML_LOCAL_OBJECT_ROOT") or None,
        )
        config.validate()
        return config

    def validate(self) -> None:
        if not DEPLOYMENT_PATTERN.fullmatch(self.deployment_id):
            raise ValueError("invalid deployment ID")
        if self.provider not in PROVIDER_SCHEMES:
            raise ValueError("unsupported provider")
        if not SHA256_PATTERN.fullmatch(self.run_spec_sha256):
            raise ValueError("invalid run-spec SHA-256")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", self.oci_digest):
            raise ValueError("invalid OCI digest")
        if not 15 <= self.maximum_runtime_minutes <= 720:
            raise ValueError("maximum runtime is outside the accepted bounds")
        expected_suffix = f"/run-specs/{self.deployment_id}/{self.run_spec_sha256}.json"
        if not self.run_spec_uri.endswith(expected_suffix):
            raise ValueError("run-spec URI is not bound to deployment and checksum")
        if not self.data_uri.endswith("/"):
            raise ValueError("data URI must be a prefix ending in a slash")
        expected_results_suffix = f"/runs/{self.deployment_id}/results/"
        if not self.results_uri.endswith(expected_results_suffix):
            raise ValueError("results URI is not bound to deployment")
        expected_scheme = PROVIDER_SCHEMES[self.provider]
        for name, uri in (
            ("run-spec", self.run_spec_uri),
            ("data", self.data_uri),
            ("results", self.results_uri),
        ):
            parsed = urlparse(uri)
            if parsed.scheme != expected_scheme or not parsed.netloc or parsed.query or parsed.fragment:
                raise ValueError(f"{name} URI does not match provider {self.provider}")
        if self.provider == "azure":
            client_id = os.environ.get("ML_WORKLOAD_IDENTITY_CLIENT_ID", "")
            if self.local_object_root is None and not UUID_PATTERN.fullmatch(client_id):
                raise ValueError("Azure workload identity client ID is missing or invalid")
        elif "ML_WORKLOAD_IDENTITY_CLIENT_ID" in os.environ:
            raise ValueError("Azure workload identity client ID is accepted only for Azure")
        if self.local_object_root is not None:
            root = Path(self.local_object_root)
            if not root.is_absolute() or root.is_symlink() or not root.is_dir():
                raise ValueError("local object root must be an absolute non-symlink directory")


class ObjectStore(ABC):
    @abstractmethod
    def read_version(self, uri: str, object_version: str) -> bytes:
        raise NotImplementedError

    @abstractmethod
    def read(self, uri: str) -> bytes:
        raise NotImplementedError

    @abstractmethod
    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        raise NotImplementedError


def bucket_and_key(uri: str, scheme: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != scheme or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError(f"invalid {scheme} object URI")
    key = parsed.path.lstrip("/")
    validate_relative_path(key)
    return parsed.netloc, key


class S3ObjectStore(ObjectStore):
    def __init__(self) -> None:
        self.client = boto3.client("s3")

    def read_version(self, uri: str, object_version: str) -> bytes:
        bucket, key = bucket_and_key(uri, "s3")
        response = self.client.get_object(Bucket=bucket, Key=key, VersionId=object_version)
        return response["Body"].read()

    def read(self, uri: str) -> bytes:
        bucket, key = bucket_and_key(uri, "s3")
        return self.client.get_object(Bucket=bucket, Key=key)["Body"].read()

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

    def read(self, uri: str) -> bytes:
        bucket, key = bucket_and_key(uri, "gs")
        return self.client.bucket(bucket).blob(key).download_as_bytes()

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
    if blob_name:
        validate_relative_path(blob_name)
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

    def read(self, uri: str) -> bytes:
        account, container, blob_name = azure_parts(uri)
        blob = BlobClient(
            account_url=f"https://{account}.blob.core.windows.net",
            container_name=container,
            blob_name=blob_name,
            credential=self.credential,
        )
        return blob.download_blob().readall()

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


class LocalObjectStore(ObjectStore):
    """Filesystem-backed provider URI adapter used only by the local image target."""

    def __init__(self, root: str) -> None:
        self.root = Path(root).resolve(strict=True)

    def _path(self, uri: str) -> Path:
        parsed = urlparse(uri)
        if parsed.scheme not in set(PROVIDER_SCHEMES.values()) or not parsed.netloc:
            raise ValueError("local adapter received an unsupported URI")
        if parsed.query or parsed.fragment:
            raise ValueError("local adapter URI may not contain query or fragment")
        relative = PurePosixPath(parsed.scheme, parsed.netloc, parsed.path.lstrip("/"))
        validate_relative_path(relative.as_posix())
        candidate = self.root.joinpath(*relative.parts)
        candidate.relative_to(self.root)
        return candidate

    def read_version(self, uri: str, object_version: str) -> bytes:
        if object_version != "local-v1":
            raise ValueError("local run-spec object version must be local-v1")
        return self.read(uri)

    def read(self, uri: str) -> bytes:
        path = self._path(uri)
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"local object is not a regular non-symlink file: {uri}")
        return path.read_bytes()

    def create(self, uri: str, payload: bytes, content_type: str) -> None:
        del content_type
        path = self._path(uri)
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)


def object_store(config: RuntimeConfig) -> ObjectStore:
    if config.local_object_root is not None:
        return LocalObjectStore(config.local_object_root)
    implementations = {"aws": S3ObjectStore, "gcp": GcsObjectStore, "azure": AzureObjectStore}
    return implementations[config.provider]()


def validate_relative_path(path: str) -> None:
    pure_path = PurePosixPath(path)
    if path.startswith("/") or path.endswith("/") or "\\" in path:
        raise ValueError("path must be a relative object path")
    if not pure_path.parts or any(part in {"", ".", ".."} for part in pure_path.parts):
        raise ValueError("path contains an unsafe component")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,254}", path):
        raise ValueError("path contains unsupported characters or is too long")


def verify_payload(payload: bytes, expected_sha256: str, expected_bytes: int, label: str) -> None:
    if len(payload) != expected_bytes:
        raise ValueError(f"{label} byte size does not match the immutable contract")
    if sha256(payload) != expected_sha256:
        raise ValueError(f"{label} SHA-256 does not match the immutable contract")


@dataclass(frozen=True)
class Artifact:
    path: str
    content_type: str
    payload: bytes

    def __post_init__(self) -> None:
        validate_relative_path(self.path)
        if self.path == RESULT_MANIFEST_PATH:
            raise ValueError("result manifest cannot list itself as an artifact")
        if not self.payload:
            raise ValueError("artifact payload may not be empty")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*", self.content_type):
            raise ValueError("artifact content type is invalid")

    def manifest_entry(self) -> dict[str, Any]:
        return {
            "bytes": len(self.payload),
            "content_type": self.content_type,
            "path": self.path,
            "sha256": sha256(self.payload),
        }


def input_schema(table: arrow.Table) -> list[dict[str, Any]]:
    return [
        {"name": field.name, "type": str(field.type), "nullable": field.nullable}
        for field in table.schema
    ]


def validate_input(payload: bytes, run_spec: RunSpec) -> tuple[arrow.Table, pd.DataFrame]:
    verify_payload(payload, run_spec.input.sha256, run_spec.input.bytes, "synthetic input")
    table = parquet.read_table(io.BytesIO(payload))
    expected_schema = [field.model_dump() for field in run_spec.input.schema_fields]
    if input_schema(table) != expected_schema:
        raise ValueError("synthetic input schema does not match the frozen contract")
    frame = table.to_pandas()
    schema = pandera.DataFrameSchema(
        {
            "row_id": pandera.Column("int64", checks=pandera.Check.in_range(0, 63), nullable=False),
            "segment": pandera.Column(str, checks=pandera.Check.isin(["a", "b", "c", "d"]), nullable=False),
            "feature_a": pandera.Column(float, nullable=False),
            "feature_b": pandera.Column(float, nullable=False),
            "feature_c": pandera.Column(float, nullable=False),
            "target": pandera.Column(float, nullable=False),
            "class_label": pandera.Column("int8", checks=pandera.Check.isin([0, 1]), nullable=False),
        },
        checks=pandera.Check(lambda data: len(data) == 64, error="fixture must contain exactly 64 rows"),
        coerce=False,
        ordered=True,
        strict=True,
    )
    schema.validate(frame, lazy=True)
    return table, frame


def logical_results(table: arrow.Table, frame: pd.DataFrame, working_directory: Path) -> dict[str, Any]:
    parquet_path = working_directory / "input.parquet"
    parquet.write_table(table, parquet_path, compression="NONE", use_dictionary=False, version="2.6")
    with duckdb.connect() as connection:
        duckdb_result = connection.execute(
            """
            SELECT count(*)::BIGINT, min(row_id)::BIGINT, max(row_id)::BIGINT,
                   sum(class_label)::BIGINT, sum(feature_a)::DOUBLE, sum(feature_b)::DOUBLE,
                   sum(feature_c)::DOUBLE, sum(target)::DOUBLE
            FROM read_parquet(?)
            """,
            [str(parquet_path)],
        ).fetchone()
    polars_frame = pl.scan_parquet(parquet_path).collect()
    segment_counts = {
        row["segment"]: int(row["len"])
        for row in polars_frame.group_by("segment").len().sort("segment").to_dicts()
    }
    arrow_target_sum = float(arrow_compute.sum(table["target"]).as_py())
    if not np.isclose(arrow_target_sum, float(frame["target"].sum()), rtol=0.0, atol=1e-12):
        raise ValueError("PyArrow and pandas target sums disagree")
    return {
        "row_count": int(duckdb_result[0]),
        "row_id_min": int(duckdb_result[1]),
        "row_id_max": int(duckdb_result[2]),
        "class_positive_count": int(duckdb_result[3]),
        "feature_a_sum": round(float(duckdb_result[4]), 12),
        "feature_b_sum": round(float(duckdb_result[5]), 12),
        "feature_c_sum": round(float(duckdb_result[6]), 12),
        "target_sum": round(float(duckdb_result[7]), 12),
        "segment_counts": segment_counts,
    }


def transformed_parquet(table: arrow.Table) -> bytes:
    feature_sum = arrow_compute.add(
        arrow_compute.add(table["feature_a"], table["feature_b"]),
        table["feature_c"],
    )
    transformed = table.append_column("feature_sum", feature_sum)
    buffer = io.BytesIO()
    parquet.write_table(
        transformed,
        buffer,
        compression="NONE",
        data_page_version="1.0",
        use_dictionary=False,
        version="2.6",
        write_statistics=True,
    )
    return buffer.getvalue()


def ray_objective(config: dict[str, float]) -> None:
    tune.report({"loss": float((config["scale"] - 1.0) ** 2)})


def exercise_ray_tune(
    seed: int,
    trials: int,
    working_directory: Path,
) -> dict[str, Any]:
    ray_directory = working_directory / "ray"
    ray_results = working_directory / "ray-results"
    ray.init(
        num_cpus=1,
        object_store_memory=80 * 1024 * 1024,
        include_dashboard=False,
        log_to_driver=False,
        _temp_dir=str(ray_directory),
    )
    try:
        tuner = tune.Tuner(
            ray_objective,
            param_space={"scale": tune.grid_search([1.0])},
            tune_config=tune.TuneConfig(metric="loss", mode="min", max_concurrent_trials=1),
            run_config=tune.RunConfig(
                name=f"tool-complete-dummy-{seed}",
                storage_path=str(ray_results),
            ),
        )
        result_grid = tuner.fit()
        if len(result_grid) != trials or any(result.error for result in result_grid):
            raise ValueError("single-node Ray Tune did not finish every bounded trial")
        best = result_grid.get_best_result(metric="loss", mode="min")
        return {"best_loss": round(float(best.metrics["loss"]), 12), "trials": len(result_grid)}
    finally:
        ray.shutdown()


@dataclass(frozen=True)
class HpoInputs:
    linear_prediction: np.ndarray
    y_test: np.ndarray


def exercise_optuna(inputs: HpoInputs, trials: int) -> dict[str, Any]:
    optuna.logging.set_verbosity(optuna.logging.WARNING)
    study = optuna.create_study(
        direction="minimize",
        sampler=optuna.samplers.GridSampler({"scale": [1.0]}),
    )

    def objective(trial: optuna.Trial) -> float:
        scale = float(trial.suggest_categorical("scale", [1.0]))
        return float(np.mean((inputs.y_test - inputs.linear_prediction * scale) ** 2))

    study.optimize(objective, n_trials=trials)
    return {"best_value": round(float(study.best_value), 12), "trials": len(study.trials)}


def exercise_mlflow(
    frame: pd.DataFrame,
    input_uri: str,
    run_spec: RunSpec,
    run_spec_sha256: str,
    provider: str,
    oci_digest: str,
    metrics: dict[str, Any],
    model_document: dict[str, Any],
    shap_report: dict[str, Any],
    optuna_result: dict[str, Any],
    ray_result: dict[str, Any],
    working_directory: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    tracking_database = working_directory / "mlflow.db"
    artifact_root = working_directory / "mlflow-artifacts"
    artifact_root.mkdir()
    tracking_uri = f"sqlite:///{tracking_database}"
    experiment_name = "tool-complete-dummy"
    mlflow.set_tracking_uri(tracking_uri)
    setup_client = mlflow.MlflowClient(tracking_uri=tracking_uri)
    experiment_id = setup_client.create_experiment(
        experiment_name,
        artifact_location=artifact_root.as_uri(),
    )
    package_lock_sha256 = sha256(PACKAGE_LOCK_PATH.read_bytes())
    feature_set_sha256 = sha256(canonical_json(["feature_a", "feature_b", "feature_c"]))
    fold_definition_sha256 = sha256(b"synthetic-row-id-modulo-4-v1")
    schema_sha256 = sha256(canonical_json([field.model_dump() for field in run_spec.input.schema_fields]))
    mlflow_dataset_digest = f"sha256:{run_spec.input.sha256[:29]}"

    with mlflow.start_run(
        experiment_id=experiment_id,
        run_name="tool-complete-dummy",
        tags={
            "run_kind": "common-conformance-smoke",
            "compute.arch": "x86_64",
            "compute.provider": provider,
            "workload": "tool-complete-dummy",
        },
    ) as smoke_run:
        mlflow_run_id = smoke_run.info.run_id
        mlflow.log_params(
            {
                "config_sha256": run_spec_sha256,
                "dataset_manifest_sha256": run_spec.input.sha256,
                "environment_lock_sha256": package_lock_sha256,
                "feature_set_sha256": feature_set_sha256,
                "fold_definition_sha256": fold_definition_sha256,
                "gold_schema_sha256": schema_sha256,
                "image_digest": oci_digest,
                "seed": run_spec.seed,
            }
        )
        dataset = mlflow.data.from_polars(
            pl.from_pandas(frame),
            source=input_uri,
            targets="target",
            name="synthetic-provider-local-input",
            digest=mlflow_dataset_digest,
        )
        mlflow.log_input(dataset, context="training")
        mlflow.log_metrics(
            {
                "mean/linear_rmse": metrics["models"]["linear_rmse"],
                "mean/xgboost_rmse": metrics["models"]["xgboost_rmse"],
                "mean/catboost_rmse": metrics["models"]["catboost_rmse"],
                "mean/lightgbm_rmse": metrics["models"]["lightgbm_rmse"],
                "mean/calibration_brier": metrics["calibration"]["brier"],
                "hpo/optuna_best_value": optuna_result["best_value"],
                "hpo/ray_best_loss": ray_result["best_loss"],
            }
        )
        mlflow.log_dict(model_document, "models/linear-model.json")
        mlflow.log_dict(shap_report, "explanations/shap.json")
        run_manifest = {
            "candidate_generator_version": "not-applicable-synthetic",
            "checkpoint": "synthetic",
            "config_hash": run_spec_sha256,
            "dataset_manifest_hash": run_spec.input.sha256,
            "dataset_snapshot_id": f"synthetic-{run_spec.input.sha256[:12]}",
            "environment_lock_hash": package_lock_sha256,
            "feature_set_hash": feature_set_sha256,
            "fold_definition_hash": fold_definition_sha256,
            "git_commit": "bound-by-reviewed-image-source-manifest",
            "gold_schema_hash": schema_sha256,
            "image_digest": oci_digest,
            "mlflow_run_id": mlflow_run_id,
            "mlflow_sync_status": "ephemeral-local-verified",
            "mlflow_tracking_uri_identity": "ephemeral-local-sqlite",
            "model_family": "bounded-multi-family-smoke",
            "region": "synthetic",
            "run_id": mlflow_run_id,
            "schema_version": "1.0.0",
            "seed": run_spec.seed,
        }
        mlflow.log_dict(run_manifest, "recovery/run_manifest.json")

    client = mlflow.MlflowClient(tracking_uri=tracking_uri)
    stored_run = client.get_run(mlflow_run_id)
    stored_runs = client.search_runs([experiment_id], max_results=2)
    if len(stored_runs) != 1 or stored_runs[0].info.run_id != mlflow_run_id:
        raise ValueError("ephemeral MLflow smoke must contain exactly one run")
    if not stored_run.inputs.dataset_inputs:
        raise ValueError("MLflow run is missing its Polars Dataset lineage")
    if stored_run.inputs.dataset_inputs[0].dataset.digest != mlflow_dataset_digest:
        raise ValueError("MLflow Dataset digest does not match its deterministic SHA-256 projection")
    artifact_paths = sorted(item.path for item in client.list_artifacts(mlflow_run_id))
    if artifact_paths != ["explanations", "models", "recovery"]:
        raise ValueError("MLflow artifacts do not match the expected bounded paths")
    required_metrics = {
        "hpo/optuna_best_value",
        "hpo/ray_best_loss",
        "mean/calibration_brier",
        "mean/catboost_rmse",
        "mean/lightgbm_rmse",
        "mean/linear_rmse",
        "mean/xgboost_rmse",
    }
    if set(stored_run.data.metrics) != required_metrics:
        raise ValueError("MLflow explicit metrics do not match the bounded smoke contract")
    tracking = {
        "artifact_roots": artifact_paths,
        "backend": "ephemeral-local-sqlite",
        "dataset_digest_bound": True,
        "dataset_digest_projection": mlflow_dataset_digest,
        "dataset_full_sha256_parameter_bound": True,
        "dataset_source_is_provider_local": True,
        "explicit_metrics_logged": True,
        "nested_runs_enabled": False,
        "run_finished": stored_run.info.status == "FINISHED",
        "persistent_service_ready": False,
        "run_count": len(stored_runs),
        "system_metrics_enabled": False,
    }
    return tracking, run_manifest


def exercise_models(
    frame: pd.DataFrame,
    run_spec: RunSpec,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], HpoInputs]:
    feature_names = ["feature_a", "feature_b", "feature_c"]
    matrix = frame[feature_names].to_numpy(dtype=np.float64)
    target = frame["target"].to_numpy(dtype=np.float64)
    labels = frame["class_label"].to_numpy(dtype=np.int8)
    test_mask = frame["row_id"].to_numpy() % 4 == 0
    train_mask = ~test_mask
    x_train, x_test = matrix[train_mask], matrix[test_mask]
    y_train, y_test = target[train_mask], target[test_mask]

    linear = LinearRegression().fit(x_train, y_train)
    linear_prediction = linear.predict(x_test)
    linear_rmse = float(root_mean_squared_error(y_test, linear_prediction))
    ols = sm.OLS(y_train, sm.add_constant(x_train)).fit()

    xgb_model = XGBRegressor(
        objective="reg:squarederror",
        n_estimators=4,
        max_depth=2,
        learning_rate=0.2,
        n_jobs=1,
        random_state=run_spec.seed,
        tree_method="hist",
        device="cpu",
        verbosity=0,
    ).fit(x_train, y_train)
    cat_model = CatBoostRegressor(
        iterations=4,
        depth=2,
        learning_rate=0.2,
        loss_function="RMSE",
        random_seed=run_spec.seed,
        thread_count=1,
        task_type="CPU",
        bootstrap_type="No",
        random_strength=0.0,
        allow_writing_files=False,
        verbose=False,
    ).fit(x_train, y_train)
    light_model = LGBMRegressor(
        n_estimators=4,
        max_depth=2,
        num_leaves=4,
        learning_rate=0.2,
        n_jobs=1,
        random_state=run_spec.seed,
        deterministic=True,
        force_col_wise=True,
        verbosity=-1,
    ).fit(x_train, y_train)

    classifier = LogisticRegression(random_state=run_spec.seed, solver="liblinear").fit(
        x_train, labels[train_mask]
    )
    train_scores = classifier.predict_proba(x_train)[:, 1]
    test_scores = classifier.predict_proba(x_test)[:, 1]
    calibrator = IsotonicRegression(out_of_bounds="clip").fit(train_scores, labels[train_mask])
    calibrated = calibrator.predict(test_scores)
    calibration_brier = float(brier_score_loss(labels[test_mask], calibrated))
    calibration_true, calibration_predicted = calibration_curve(
        labels[test_mask], calibrated, n_bins=4, strategy="quantile"
    )

    explainer = shap.LinearExplainer(linear, x_train)
    explanation = explainer(x_test[:4])
    reconstructed = np.asarray(explanation.base_values) + np.asarray(explanation.values).sum(axis=1)
    expected_prediction = linear.predict(x_test[:4])
    additivity_error = float(np.max(np.abs(reconstructed - expected_prediction)))

    simulation_rng = np.random.default_rng(run_spec.seed + 1)
    residual_scale = max(float(np.std(y_train - linear.predict(x_train))), 0.01)
    simulation = scipy.stats.norm.rvs(
        loc=float(np.mean(linear_prediction)),
        scale=residual_scale,
        size=128,
        random_state=simulation_rng,
    )
    metrics = {
        "calibration": {
            "brier": round(calibration_brier, 12),
            "curve_predicted": [round(float(value), 12) for value in calibration_predicted],
            "curve_true": [round(float(value), 12) for value in calibration_true],
        },
        "models": {
            "catboost_rmse": round(float(root_mean_squared_error(y_test, cat_model.predict(x_test))), 12),
            "lightgbm_rmse": round(float(root_mean_squared_error(y_test, light_model.predict(x_test))), 12),
            "linear_rmse": round(linear_rmse, 12),
            "statsmodels_r_squared": round(float(ols.rsquared), 12),
            "xgboost_rmse": round(float(root_mean_squared_error(y_test, xgb_model.predict(x_test))), 12),
        },
        "simulation": {
            "draws": len(simulation),
            "mean": round(float(np.mean(simulation)), 12),
            "p05": round(float(np.quantile(simulation, 0.05)), 12),
            "p95": round(float(np.quantile(simulation, 0.95)), 12),
        },
    }
    model = {
        "family": "sklearn-linear-regression",
        "feature_names": feature_names,
        "coefficients": [round(float(value), 12) for value in linear.coef_],
        "intercept": round(float(linear.intercept_), 12),
        "purpose": "synthetic-shape-only",
    }
    shap_report = {
        "additivity_max_abs_error": round(additivity_error, 15),
        "background_rows": len(x_train),
        "explained_output": "regression_value",
        "explained_rows": 4,
        "explainer": "LinearExplainer",
        "mean_absolute_attribution": {
            name: round(float(value), 12)
            for name, value in zip(feature_names, np.abs(explanation.values).mean(axis=0), strict=True)
        },
        "non_causal": True,
    }
    hpo_inputs = HpoInputs(
        linear_prediction=linear_prediction,
        y_test=y_test,
    )
    return metrics, model, shap_report, hpo_inputs


def enforce_expected_output(
    policy: dict[str, Any],
    logical: dict[str, Any],
    metrics: dict[str, Any],
    shap_report: dict[str, Any],
    tracking: dict[str, Any],
    artifacts: list[Artifact],
) -> None:
    if logical != policy.get("exact_logical_results"):
        raise ValueError("logical results do not match the frozen expected-output policy")
    required_paths = policy.get("required_artifacts")
    actual_paths = [artifact.path for artifact in artifacts]
    if actual_paths != required_paths:
        raise ValueError("artifact paths do not match the frozen sorted output policy")
    artifact_by_path = {artifact.path: artifact for artifact in artifacts}
    for path, expected_sha256 in policy.get("exact_artifact_sha256", {}).items():
        artifact = artifact_by_path.get(path)
        if artifact is None or sha256(artifact.payload) != expected_sha256:
            raise ValueError(f"artifact does not match its exact output policy: {path}")
    checks = policy.get("bounded_checks", {})
    if metrics["models"]["linear_rmse"] > checks["linear_rmse_max"]:
        raise ValueError("linear model smoke metric is outside its bound")
    if metrics["models"]["statsmodels_r_squared"] < checks["statsmodels_r_squared_min"]:
        raise ValueError("statsmodels smoke metric is outside its bound")
    for family in ("xgboost", "catboost", "lightgbm"):
        if metrics["models"][f"{family}_rmse"] > checks[f"{family}_rmse_max"]:
            raise ValueError(f"{family} smoke metric is outside its bound")
    if metrics["calibration"]["brier"] > checks["calibration_brier_max"]:
        raise ValueError("calibration smoke metric is outside its bound")
    if shap_report["additivity_max_abs_error"] > checks["shap_additivity_error_max"]:
        raise ValueError("SHAP additivity error is outside its bound")
    hpo_policy = policy.get("hpo_policy", {})
    if metrics["optuna"]["trials"] != hpo_policy.get("optuna_trials"):
        raise ValueError("Optuna trial count does not match the expected-output policy")
    if metrics["ray_tune"]["trials"] != hpo_policy.get("ray_tune_trials"):
        raise ValueError("Ray Tune trial count does not match the expected-output policy")
    mlflow_policy = policy.get("mlflow_policy", {})
    if tracking["run_count"] != mlflow_policy.get("run_count"):
        raise ValueError("MLflow run count does not match the expected-output policy")
    for policy_flag in (
        "dataset_digest_bound",
        "explicit_metrics_logged",
        "nested_runs_enabled",
        "system_metrics_enabled",
    ):
        if tracking.get(policy_flag) is not mlflow_policy.get(policy_flag):
            raise ValueError(f"MLflow tracking flag does not match policy: {policy_flag}")
    for required_flag in ("dataset_source_is_provider_local", "run_finished"):
        if tracking.get(required_flag) is not True:
            raise ValueError(f"MLflow tracking flag is not satisfied: {required_flag}")
    if tracking.get("persistent_service_ready") is not mlflow_policy.get(
        "persistent_tracking_service_ready"
    ):
        raise ValueError("MLflow persistent-service claim does not match the accepted policy")


class DummyWorkload:
    def __init__(
        self,
        run_spec: RunSpec,
        run_spec_sha256: str,
        input_payload: bytes,
        input_uri: str,
        provider: str,
        oci_digest: str,
    ) -> None:
        self.run_spec = run_spec
        self.run_spec_sha256 = run_spec_sha256
        self.input_payload = input_payload
        self.input_uri = input_uri
        self.provider = provider
        self.oci_digest = oci_digest

    def execute(self) -> tuple[list[Artifact], bytes]:
        policy_payload = EXPECTED_OUTPUT_PATH.read_bytes()
        if sha256(policy_payload) != self.run_spec.expected_output_policy_sha256:
            raise ValueError("expected-output policy does not match the immutable run spec")
        policy = json.loads(policy_payload)
        versions = package_versions()

        with tempfile.TemporaryDirectory(prefix="tool-complete-dummy-") as directory:
            working_directory = Path(directory)
            table, frame = validate_input(self.input_payload, self.run_spec)
            logical = logical_results(table, frame, working_directory)
            if logical != self.run_spec.input.logical_results.model_dump():
                raise ValueError("synthetic input logical results do not match the immutable run spec")
            metrics, model, shap_report, hpo_inputs = exercise_models(frame, self.run_spec)
            optuna_result = exercise_optuna(hpo_inputs, self.run_spec.limits.optuna_trials)
            ray_result = exercise_ray_tune(
                self.run_spec.seed,
                self.run_spec.limits.ray_trials,
                working_directory,
            )
            metrics["optuna"] = optuna_result
            metrics["ray_tune"] = ray_result
            tracking, run_manifest = exercise_mlflow(
                frame,
                self.input_uri,
                self.run_spec,
                self.run_spec_sha256,
                self.provider,
                self.oci_digest,
                metrics,
                model,
                shap_report,
                optuna_result,
                ray_result,
                working_directory,
            )
            transformed_payload = transformed_parquet(table)

        metrics_document = {
            "fixture_bytes": self.run_spec.input.bytes,
            "fixture_sha256": self.run_spec.input.sha256,
            "logical_results": logical,
            "metrics": metrics,
            "run_spec_sha256": self.run_spec_sha256,
            "schema_version": "1.0.0",
            "workload": self.run_spec.workload,
        }
        checkpoint = {
            "completed_stages": [
                "input-validation",
                "columnar-transforms",
                "model-families",
                "bounded-optuna",
                "single-node-ray-tune",
                "mlflow-polars-dataset-lineage",
                "mlflow-explicit-metrics-and-artifacts",
                "recovery-run-manifest",
                "shap",
                "calibration",
                "simulation",
            ],
            "fixture_sha256": self.run_spec.input.sha256,
            "recoverable_training_claim": False,
            "run_spec_sha256": self.run_spec_sha256,
            "schema_version": "1.0.0",
        }
        report = (
            "# Tool-complete dummy workload\n\n"
            "This bounded synthetic run exercises the accepted CPU-only, single-node process shape.\n"
            "It contains no production data, model selection, Spotify transformation, or production behavior.\n\n"
            f"- input rows: {logical['row_count']}\n"
            f"- package count: {len(versions)}\n"
            f"- non-root uid: {os.geteuid()}\n"
            f"- run-spec SHA-256: `{self.run_spec_sha256}`\n"
            f"- input SHA-256: `{self.run_spec.input.sha256}`\n"
        ).encode("utf-8")
        artifacts = sorted(
            [
                Artifact("checkpoints/final.json", "application/json", canonical_json(checkpoint)),
                Artifact("data/transformed.parquet", "application/vnd.apache.parquet", transformed_payload),
                Artifact("explanations/shap.json", "application/json", canonical_json(shap_report)),
                Artifact("metrics/metrics.json", "application/json", canonical_json(metrics_document)),
                Artifact("models/linear-model.json", "application/json", canonical_json(model)),
                Artifact("packages/versions.json", "application/json", canonical_json(versions)),
                Artifact("reports/conformance.md", "text/markdown", report),
                Artifact("run-manifest.json", "application/json", canonical_json(run_manifest)),
                Artifact("tracking/mlflow-artifact-tracking.json", "application/json", canonical_json(tracking)),
            ],
            key=lambda artifact: artifact.path,
        )
        enforce_expected_output(policy, logical, metrics, shap_report, tracking, artifacts)
        manifest = {
            "artifacts": [artifact.manifest_entry() for artifact in artifacts],
            "run_spec_sha256": self.run_spec_sha256,
            "schema_version": "1.0.0",
            "workload": self.run_spec.workload,
        }
        return artifacts, canonical_json(manifest)


def validate_write_journal(paths: list[str]) -> None:
    if not paths or paths[-1] != RESULT_MANIFEST_PATH:
        raise ValueError("result-manifest.json was not created last")
    if RESULT_MANIFEST_PATH in paths[:-1]:
        raise ValueError("result-manifest.json was created more than once or before an artifact")


def publish_results(
    store: ObjectStore,
    results_uri: str,
    artifacts: list[Artifact],
    manifest_payload: bytes,
) -> None:
    paths = [artifact.path for artifact in artifacts]
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise ValueError("artifact paths must be sorted and unique before publication")
    write_journal: list[str] = []
    for artifact in artifacts:
        store.create(f"{results_uri}{artifact.path}", artifact.payload, artifact.content_type)
        write_journal.append(artifact.path)
    store.create(f"{results_uri}{RESULT_MANIFEST_PATH}", manifest_payload, "application/json")
    write_journal.append(RESULT_MANIFEST_PATH)
    validate_write_journal(write_journal)


def run_workload() -> None:
    if os.geteuid() == 0:
        raise ValueError("workload must run as a non-root user")
    config = RuntimeConfig.from_environment()
    store = object_store(config)
    run_spec_payload = store.read_version(config.run_spec_uri, config.run_spec_object_version)
    actual_run_spec_sha256 = sha256(run_spec_payload)
    if actual_run_spec_sha256 != config.run_spec_sha256:
        raise ValueError("downloaded run-spec SHA-256 does not match the request")
    run_spec = RunSpec.from_bytes(run_spec_payload)
    input_uri = f"{config.data_uri}{run_spec.input.object_key}"
    input_payload = store.read(input_uri)
    verify_payload(input_payload, run_spec.input.sha256, run_spec.input.bytes, "synthetic input")

    workload = DummyWorkload(
        run_spec,
        config.run_spec_sha256,
        input_payload,
        input_uri,
        config.provider,
        config.oci_digest,
    )
    artifacts, manifest_payload = workload.execute()
    publish_results(store, config.results_uri, artifacts, manifest_payload)
    print(
        canonical_json(
            {
                "deployment_id": config.deployment_id,
                "input_sha256": run_spec.input.sha256,
                "manifest_sha256": sha256(manifest_payload),
                "package_versions": package_versions(),
                "provider": config.provider,
                "status": "succeeded",
            }
        ).decode("ascii")
    )


app = typer.Typer(add_completion=False, no_args_is_help=False, pretty_exceptions_enable=False)


@app.command("validate-install")
def validate_install_command() -> None:
    versions = package_versions()
    print(canonical_json({"package_versions": versions, "status": "install-valid"}).decode("ascii"))


@app.command("run")
def run_command() -> None:
    try:
        run_workload()
    except Exception as error:
        typer.echo(f"conformance: {type(error).__name__}: {error}", err=True)
        raise typer.Exit(code=1) from error


def main() -> int:
    try:
        result = app(standalone_mode=False)
    except typer.Exit as error:
        return int(error.exit_code)
    except Exception as error:
        print(f"conformance: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return int(result) if isinstance(result, int) else 0


if __name__ == "__main__":
    raise SystemExit(main())
