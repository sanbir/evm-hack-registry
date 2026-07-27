# Forta undelegation can be stalled

The test executes the historical Forta `StakeAllocator`/delegation implementation vendored under `src/forta/`. An attacker is added to the real delegation set and the undelegation path is driven until it stalls as reported.

```bash
forge test -vvv
```

Sources: [AuditVault finding #32467](https://github.com/Auditware/AuditVault/blob/main/findings/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.md), [Forta repository](https://github.com/forta-network/forta-contracts).
