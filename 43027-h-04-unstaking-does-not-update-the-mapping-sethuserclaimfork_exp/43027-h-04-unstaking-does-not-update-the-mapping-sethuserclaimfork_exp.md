# Stakehouse `Syndicate.unstake` leaves the claim snapshot for removed shares

> **Vulnerability classes:** vuln/wrong-condition · vuln/reward-accounting · vuln/availability
>
> **Reproduction:** the test compiles the audited Stakehouse `Syndicate.sol` source from the Code4rena snapshot and supplies only registry/token boundary doubles. A partial unstake leaves `sETHUserClaimForKnot` accounting for the pre-unstake balance, so the remaining holder's claim calculation underflows.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/43027-h-04-unstaking-does-not-update-the-mapping-sethuserclaimfork.md -->
<!-- date: 2022-11 -->

## Root cause

In the audited source, `unstake` decreases `sETHStakedBalanceForKnot` but never updates `sETHUserClaimForKnot`. The call first snapshots a claim for the full position, then removes only part of the position. Subsequent `calculateUnclaimedFreeFloatingETHShare`/`claimAsStaker` subtracts that full snapshot from the smaller position's entitlement and reverts on underflow.

The exact source is vendored at [`src/syndicate/Syndicate.sol`](src/syndicate/Syndicate.sol), from snapshot commit `08a34ed4505173e7cad2d3b2bde92863b61716c8` in [`code-423n4/2022-11-stakehouse`](https://github.com/code-423n4/2022-11-stakehouse). The Stakehouse registry API is represented by the matching call-surface boundary in [`src/stakehouse-api/contracts/StakehouseAPI.sol`](src/stakehouse-api/contracts/StakehouseAPI.sol).

## Reproduction

```bash
cd 43027-h-04-unstaking-does-not-update-the-mapping-sethuserclaimfork_exp
forge test -vvv
```

The test stakes four sETH shares, credits eight ETH to the Syndicate (four ETH becomes the free-floating reward), and unstakes two shares. The audited implementation pays the four-ETH snapshot but leaves the claim mapping at four ETH while only two shares remain. Both the preview and claim paths then revert.

Expected result: `1 passed`.

## Sources

- [AuditVault finding #43027](https://github.com/Auditware/AuditVault/blob/main/findings/43027-h-04-unstaking-does-not-update-the-mapping-sethuserclaimfork.md)
- [Code4rena Stakehouse source snapshot](https://github.com/code-423n4/2022-11-stakehouse/tree/08a34ed4505173e7cad2d3b2bde92863b61716c8)
- [Original report](https://code4rena.com/reports/2022-11-stakehouse)
