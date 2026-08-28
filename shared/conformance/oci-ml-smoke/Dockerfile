# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM python:3.14.7-slim-bookworm@sha256:6e9a7d1f48cf0127a5be29b58dba0c7f1b59c118619f011b7a6fca28d00adfd4 AS base

RUN apt-get update \
    && apt-get install --yes --no-install-recommends libgomp1 \
    && rm --recursive --force /var/lib/apt/lists/*

FROM base AS test

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1 \
    RAY_DEDUP_LOGS=0 \
    RAY_USAGE_STATS_ENABLED=0 \
    PYTHONPATH=/opt/python

COPY requirements.lock /tmp/requirements.lock
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes \
        --target /opt/python --requirement /tmp/requirements.lock \
    && PYTHONPATH=/opt/python python -m pip check \
    && rm --force /tmp/requirements.lock

WORKDIR /opt/conformance
COPY conformance.py expected-output.json package-matrix.json requirements.lock test_conformance.py /opt/conformance/

# Build-time import and negative tests do not execute the workload or contact a cloud.
RUN python /opt/conformance/conformance.py validate-install \
    && python -m pytest --disable-warnings --maxfail=1 --quiet /opt/conformance/test_conformance.py

FROM base AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1 \
    RAY_DEDUP_LOGS=0 \
    RAY_USAGE_STATS_ENABLED=0 \
    PYTHONPATH=/opt/python \
    TMPDIR=/work \
    GIT_PYTHON_REFRESH=quiet

ARG OCI_SOURCE_REVISION="uncommitted"

LABEL org.opencontainers.image.title="Demo cross-cloud ML conformance workload" \
      org.opencontainers.image.description="Provider-neutral test fixture for the disposable OCI runner contract" \
      org.opencontainers.image.source="https://github.com/Bboissen/Ray_terraform" \
      org.opencontainers.image.revision="${OCI_SOURCE_REVISION}"

WORKDIR /opt/conformance
COPY --from=test /opt/python /opt/python
COPY --from=test --chown=10001:10001 /opt/conformance/conformance.py \
    /opt/conformance/expected-output.json /opt/conformance/package-matrix.json \
    /opt/conformance/requirements.lock /opt/conformance/

RUN groupadd --system --gid 10001 conformance \
    && useradd --system --uid 10001 --gid conformance --create-home \
        --home-dir /home/conformance --shell /usr/sbin/nologin conformance \
    && install --directory --mode 0700 --owner 10001 --group 10001 /work

USER 10001:10001
ENTRYPOINT ["python", "/opt/conformance/conformance.py", "run"]
