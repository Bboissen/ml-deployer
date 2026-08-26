# Tests

Goal 02 contains dependency-free tests for the runner request, completion receipt, deployment index, lifecycle command envelope and portable guest. Provider goals add their own validation, plan-policy, trusted receipt-publication and mocked-provider tests.

Routine tests must use OpenTofu validation, plan mode, mocked providers, or dependency-free policy checks. They must never apply real infrastructure by default.
