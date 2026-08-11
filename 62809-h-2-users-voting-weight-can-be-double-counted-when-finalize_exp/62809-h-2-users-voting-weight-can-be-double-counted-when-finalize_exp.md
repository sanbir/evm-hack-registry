# BMX: An attacker with two addresses in different finalizeEpoch tally batches unstakes 1000e18 s

> **Vulnerability classes:** vuln/unfair-mint
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62809-h-2-users-voting-weight-can-be-double-counted-when-finalize.md -->

## Root cause

An attacker with two addresses in different finalizeEpoch tally batches unstakes 1000e18 sbfBMX from an already-tallied address and restakes it to a not-yet-tallied one, so the same balance is counted twice — a voting option's weight is inflated to 2000e18 (2x the real 1000e18 stake), crediting 1000e18 phantom vote weight to the attacker's chosen option.

```solidity
            if (userVoteWeight[ep][voterAddr] > 0) continue;

            //@audit current balance is used for voterAddr
            uint256 bal = SBF_BMX.balanceOf(voterAddr); // @> live balance read at tally time — enables cross-batch double-count
            if (bal == 0) {
                // queue for removal instead of removing now
```

## Why it's exploitable here

An attacker with two addresses in different finalizeEpoch tally batches unstakes 1000e18 sbfBMX from an already-tallied address and restakes it to a not-yet-tallied one, so the same balance is counted twice — a voting option's weight is inflated to 2000e18 (2x the real 1000e18 stake), crediting 1000e18 phantom vote weight to the attacker's chosen option.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["An attacker with two addresses in different finalizeEpoch tally batche"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L97** — VULN step 1: live balance read at tally time — enables cross-batch double-count

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62809-h-2-users-voting-weight-can-be-double-counted-when-finalize_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An attacker with two addresses in different finalizeEpoch tally batches unstakes 1000e18 sbfBMX from an already-tallied address and restakes**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
