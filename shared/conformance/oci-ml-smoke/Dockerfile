# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM python:3.12.12-bookworm@sha256:c0abd0758831ad99b7a29e0c1a875da9c4abb9a2e3f21e2eeb585dbcadfb6cd0

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1 \
    RAY_DEDUP_LOGS=0 \
    RAY_USAGE_STATS_ENABLED=0

RUN groupadd --system --gid 10001 conformance \
    && useradd --system --uid 10001 --gid conformance --create-home --home-dir /home/conformance --shell /usr/sbin/nologin conformance

COPY requirements.lock /tmp/requirements.lock
RUN python -m pip install --no-cache-dir --only-binary=:all: --require-hashes --requirement /tmp/requirements.lock \
    && python -m pip check \
    && rm --force /tmp/requirements.lock

ARG OCI_SOURCE_REVISION="uncommitted"

LABEL org.opencontainers.image.title="Demo cross-cloud ML conformance workload" \
      org.opencontainers.image.description="Provider-neutral test fixture for the disposable OCI runner contract" \
      org.opencontainers.image.source="https://github.com/Bboissen/Ray_terraform" \
      org.opencontainers.image.revision="${OCI_SOURCE_REVISION}"

WORKDIR /opt/conformance
COPY --chown=10001:10001 conformance.py expected-output.json package-matrix.json requirements.lock test_conformance.py /opt/conformance/

# Build-time import and negative tests do not execute the workload or contact a cloud.
RUN python /opt/conformance/conformance.py validate-install \
    && python -m pytest --disable-warnings --maxfail=1 --quiet /opt/conformance/test_conformance.py

USER 10001:10001
ENTRYPOINT ["python", "/opt/conformance/conformance.py", "run"]
