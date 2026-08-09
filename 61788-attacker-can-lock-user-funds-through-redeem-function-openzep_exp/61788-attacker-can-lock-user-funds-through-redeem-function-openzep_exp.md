# f(x) Protocol: An attacker uses dust redeems (no minimum rawDebt) to append 800+ child nodes to a tick's 

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/61788-attacker-can-lock-user-funds-through-redeem-function-openzep.md -->

## Root cause

An attacker uses dust redeems (no minimum rawDebt) to append 800+ child nodes to a tick's parent-pointer chain; the verbatim recursive TickLogic._getRootNodeAndCompress then exhausts the 30M block gas limit whenever a victim calls operate() to close/update a position in that tick, permanently locking the victim's 100e18 collateral (position becomes un-closable), while the PR #22 iterative fix reso

```solidity
            uint256 debtRatioCompressed;
            (root, collRatioCompressed, debtRatioCompressed) = _getRootNodeAndCompress(parent); // @> unbounded recursion: reverts (stack overflow / OOG) on attacker-lengthened chains
            collRatio = (collRatio * collRatioCompressed) >> 60;
            debtRatio = (debtRatio * debtRatioCompressed) >> 60;
            metadata = metadata.insertUint(root, PARENT_OFFSET, 48);
            metadata = metadata.insertUint(collRatio, COLL_RATIO_OFFSET, 64);
```

## Why it's exploitable here

An attacker uses dust redeems (no minimum rawDebt) to append 800+ child nodes to a tick's parent-pointer chain; the verbatim recursive TickLogic._getRootNodeAndCompress then exhausts the 30M block gas limit whenever a victim calls operate() to close/update a position in that tick, permanently locking the victim's 100e18 collateral (position becomes un-closable), while the PR #22 iterative fix resolves the identical chain in <1.2M gas.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  S1["VULN step 2"]
  H["An attacker uses dust redeems (no minimum rawDebt) to append 800+ chil"]
  S0 --> S1
  S1 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L159** — VULN step 1: unbounded recursion: reverts (stack overflow / OOG) on attacker-lengthened chains
2. **L162** — VULN step 2: unbounded recursion: reverts (stack overflow / OOG) on attacker-lengthened chains

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 61788-attacker-can-lock-user-funds-through-redeem-function-openzep_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An attacker uses dust redeems (no minimum rawDebt) to append 800+ child nodes to a tick's parent-pointer chain; the verbatim recursive TickL**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
