# Shared contracts

This directory contains provider-neutral runner contracts, the genuinely portable guest execution core, and the bounded OCI conformance fixture used to accept that infrastructure.

It must not contain provider configurations, provider-specific IAM generation, production ML code, experiment parameters, or a lowest-common-denominator wrapper around cloud resources. The test-only fixture under `conformance/` may exercise representative libraries and provider-local object adapters, but it may not grow into the ML product repository.
