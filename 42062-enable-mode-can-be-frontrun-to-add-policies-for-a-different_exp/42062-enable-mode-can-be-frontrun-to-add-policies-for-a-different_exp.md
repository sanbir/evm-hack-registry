# SmartSessions enable mode: signed policies can target another permission

This reproduction uses the real SmartSessions production source from the historical vulnerable parent of commit [`21af6ae`](https://github.com/erc7579/smartsessions/commit/21af6aee19a831d214ef720c35d15d14b2663f78), dated 2024-09-11. The fix moved the `permissionId` equality check in `contracts/SmartSession.sol` outside the “validator already set” branch. The test also compiles the fixed source and checks that it rejects the same payload.

The test installs a real session for `permissionA`, then submits an enable payload whose signed `sessionToEnable` hashes to a different `permissionB` while carrying an action policy. The vulnerable source skips the binding check because `permissionA` already has a validator and stores the new action policy under `permissionA`. The fixed source reverts with `InvalidPermissionId`.

The account, policy, validator, and registry are minimal ABI-boundary doubles; the state transition, digest calculation, compression, decoding, nonce increment, and policy storage are the historical production implementation.

## Reproduce

```bash
forge test -vvv
```

Expected result: one passing test. It demonstrates the vulnerable acceptance and the fixed rejection.

## Sources

- [Vulnerable SmartSession parent (`7c4dd7f`)](https://github.com/erc7579/smartsessions/tree/7c4dd7f2afcb22238b91956a3ab7f7742b278b3d/contracts)
- [Fix commit `21af6ae`](https://github.com/erc7579/smartsessions/commit/21af6aee19a831d214ef720c35d15d14b2663f78)
- [AuditVault finding #42062](https://github.com/Auditware/AuditVault/blob/main/findings/42062-enable-mode-can-be-frontrun-to-add-policies-for-a-different.md)
