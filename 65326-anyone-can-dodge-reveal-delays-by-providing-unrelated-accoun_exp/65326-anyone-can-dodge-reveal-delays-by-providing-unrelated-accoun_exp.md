# Statusl: An insider slasher dodges the commit-reveal delay queue by committing against an unused

> **Vulnerability classes:** vuln/locked-funds · vuln/unfair-mint · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65326-anyone-can-dodge-reveal-delays-by-providing-unrelated-accoun.md -->

## Root cause

An insider slasher dodges the commit-reveal delay queue by committing against an unused, unrelated account (0-delay revealStartTime) and revealing in the same block, minting the 1-token slashing reward to the attacker EOA that the honest, delay-abiding slasher should have received.

```solidity
        }

        delete slashCommitments[account][hash];
        slash(privateKey, rewardRecipient); // @> pays out without ever checking account == members[poseidonHash(privateKey)] — an unrelated account skips the reveal-delay queue
    }

```

## Why it's exploitable here

An insider slasher dodges the commit-reveal delay queue by committing against an unused, unrelated account (0-delay revealStartTime) and revealing in the same block, minting the 1-token slashing reward to the attacker EOA that the honest, delay-abiding slasher should have received.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["An insider slasher dodges the commit-reveal delay queue by committing "]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L167** — VULN step 1: pays out without ever checking account == members[poseidonHash(privateKey)] — an unrelated account skips the reveal-delay queue

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65326-anyone-can-dodge-reveal-delays-by-providing-unrelated-accoun_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An insider slasher dodges the commit-reveal delay queue by committing against an unused, unrelated account (0-delay revealStartTime) and rev**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
