# Azure roots

- `bootstrap`: dedicated Entra-authenticated Blob backend resources; local
  bootstrap state.
- `platform`: persistent workload storage/control containers, ACR, private Blob
  endpoint, VNet/subnets, deny-all-inbound NSG, writer role, and unattached
  trusted publisher.
- `runner`: one resource group containing the VM, disk, NIC, deployment managed
  identity/grants, outbound Standard public address, and shutdown schedule.

There is no persistent NAT Gateway. The runner-owned address exists only for
outbound access and is removed with runner state. The subnet NSG denies all
inbound traffic; normal administration uses Azure Run Command.

No root accepts a storage key, SAS token, client secret, or private SSH key.
Platform and runner backends use reviewed bootstrap output and Entra identity.
Runner/platform preconditions bind separate state/workload storage and the
closed platform checksum.

Run the full backend-disabled provider test from the repository root:

```bash
bash tests/azure/test-scaffold.sh
```

It performs locked `init -backend=false`, `validate`, policy checks, and
fail-closed mutations. It does not prove current subscription state, role
assignment authority, Blob conditional-expression support, quota, or capacity.
