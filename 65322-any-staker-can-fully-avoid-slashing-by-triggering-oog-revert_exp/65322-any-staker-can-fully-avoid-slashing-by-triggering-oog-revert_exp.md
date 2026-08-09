# Statusl: A staker who pre-registers thousands of vaults makes slash()'s unbounded per-vault reward-

> **Vulnerability classes:** vuln/locked-funds · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65322-any-staker-can-fully-avoid-slashing-by-triggering-oog-revert.md -->

## Root cause

A staker who pre-registers thousands of vaults makes slash()'s unbounded per-vault reward-aggregation loop exceed the block gas limit, so slash() always OOG-reverts and the protocol can never seize the staker's 1000e18 slashable stake (slashing fully evaded).

```solidity
        uint256 accountTotalRewards = 0;

        for (uint256 i = 0; i < accountVaults.length; i++) {
            accountTotalRewards += rewardsBalanceOf(accountVaults[i]); // @> unbounded loop over attacker-controlled accountVaults → slash() OOGs (slash DoS/evasion)
        }
        return accountTotalRewards;
```

## Why it's exploitable here

A staker who pre-registers thousands of vaults makes slash()'s unbounded per-vault reward-aggregation loop exceed the block gas limit, so slash() always OOG-reverts and the protocol can never seize the staker's 1000e18 slashable stake (slashing fully evaded).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["A staker who pre-registers thousands of vaults makes slash()'s unbound"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L139** — VULN step 1: unbounded loop over attacker-controlled accountVaults → slash() OOGs (slash DoS/evasion)

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65322-any-staker-can-fully-avoid-slashing-by-triggering-oog-revert_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A staker who pre-registers thousands of vaults makes slash()'s unbounded per-vault reward-aggregation loop exceed the block gas limit, so sl**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
