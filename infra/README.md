# OpenTofu roots

AWS, Google Cloud and Azure are independent implementations of the accepted
Goal 02 contract. Every provider keeps separate bootstrap, persistent platform
and disposable runner roots and state boundaries:

```text
infra/
  aws/{bootstrap,platform,runner}
  gcp/{bootstrap,platform,runner}
  azure/{bootstrap,platform,runner}
```

The providers share request, receipt and guest behavior, not resource modules
or provider configuration. Each provider README documents its closed platform
binding, backend boundary and account-specific live review gates.

Run all three scaffold checks from the repository root:

```bash
make scaffold-test
```

The checks do not authenticate to or call a cloud API. OpenTofu may download
the exactly locked provider packages from its registry when they are not
already cached.

Passing the scaffold checks is not provider-goal acceptance and does not
authorize backend initialization, planning, applying, importing, state changes
or resource destruction.

The accepted layout is documented in [`../docs/architecture.md`](../docs/architecture.md).
