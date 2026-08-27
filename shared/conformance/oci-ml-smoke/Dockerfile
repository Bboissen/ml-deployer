# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

FROM python:3.14.7-slim-bookworm@sha256:6e9a7d1f48cf0127a5be29b58dba0c7f1b59c118619f011b7a6fca28d00adfd4

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    OMP_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    NUMEXPR_NUM_THREADS=1

RUN groupadd --system --gid 10001 conformance \
    && useradd --system --uid 10001 --gid conformance --home-dir /nonexistent --shell /usr/sbin/nologin conformance

COPY requirements.lock /tmp/requirements.lock
RUN python -m pip install --no-cache-dir --require-hashes --requirement /tmp/requirements.lock \
    && rm --force /tmp/requirements.lock

ARG OCI_SOURCE_REVISION="uncommitted"

LABEL org.opencontainers.image.title="Demo cross-cloud ML conformance workload" \
      org.opencontainers.image.description="Provider-neutral test fixture for the disposable OCI runner contract" \
      org.opencontainers.image.source="https://github.com/Bboissen/Ray_terraform" \
      org.opencontainers.image.revision="${OCI_SOURCE_REVISION}"

WORKDIR /opt/conformance
COPY --chown=10001:10001 conformance.py /opt/conformance/conformance.py

# Build-time import verification does not execute the workload or contact a cloud.
RUN python /opt/conformance/conformance.py --validate-install

USER 10001:10001
ENTRYPOINT ["python", "/opt/conformance/conformance.py"]
