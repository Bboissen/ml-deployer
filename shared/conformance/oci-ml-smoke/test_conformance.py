from __future__ import annotations

import importlib.metadata
from pathlib import Path

import pytest
from pydantic import ValidationError

import conformance


def logical_results() -> dict[str, object]:
    return {
        "row_count": 64,
        "row_id_min": 0,
        "row_id_max": 63,
        "class_positive_count": 31,
        "feature_a_sum": 0.0,
        "feature_b_sum": 0.0,
        "feature_c_sum": -1.0,
        "target_sum": -0.875,
        "segment_counts": {"a": 16, "b": 16, "c": 16, "d": 16},
    }


def test_mutable_input_key_is_rejected() -> None:
    with pytest.raises(ValidationError, match="content-addressed"):
        conformance.InputSpec(
            object_key="fixtures/tool-complete-dummy/latest.parquet",
            bytes=10,
            sha256="a" * 64,
            schema=[],
            logical_results=logical_results(),
        )


def test_wrong_checksum_is_rejected() -> None:
    with pytest.raises(ValueError, match="SHA-256"):
        conformance.verify_payload(b"exact-bytes", "0" * 64, 11, "synthetic input")


def test_missing_package_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    original = importlib.metadata.version

    def missing(distribution: str) -> str:
        if distribution == "numpy":
            raise importlib.metadata.PackageNotFoundError(distribution)
        return original(distribution)

    monkeypatch.setattr(importlib.metadata, "version", missing)
    with pytest.raises(importlib.metadata.PackageNotFoundError):
        conformance.package_versions(Path(__file__).with_name("package-matrix.json"))


def test_result_manifest_must_be_last() -> None:
    with pytest.raises(ValueError, match="created last"):
        conformance.validate_write_journal(["result-manifest.json", "metrics/metrics.json"])


def test_output_escape_is_rejected() -> None:
    with pytest.raises(ValueError, match="unsafe"):
        conformance.Artifact("../escape.json", "application/json", b"{}")


def runtime_config(provider: str, scheme: str) -> conformance.RuntimeConfig:
    digest = "b" * 64
    return conformance.RuntimeConfig(
        deployment_id="dummy-001",
        provider=provider,
        run_spec_uri=f"{scheme}://example/run-specs/dummy-001/{digest}.json",
        run_spec_sha256=digest,
        run_spec_object_version="v1",
        data_uri=f"{scheme}://example/",
        results_uri=f"{scheme}://example/runs/dummy-001/results/",
        oci_digest=f"sha256:{'c' * 64}",
        maximum_runtime_minutes=15,
    )


def test_provider_mismatch_is_rejected() -> None:
    with pytest.raises(ValueError, match="does not match provider"):
        runtime_config("aws", "gs").validate()


def test_unsupported_cloud_is_rejected() -> None:
    with pytest.raises(ValueError, match="unsupported provider"):
        runtime_config("digitalocean", "https").validate()


def test_quick_profile_rejects_extra_trials() -> None:
    with pytest.raises(ValidationError):
        conformance.Limits(rows=64, optuna_trials=2, ray_trials=1, ray_cpus=1)
