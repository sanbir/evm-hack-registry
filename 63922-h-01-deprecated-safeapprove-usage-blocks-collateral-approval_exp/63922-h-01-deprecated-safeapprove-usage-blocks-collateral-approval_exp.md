# Hyperlend: After the first successful collateral supply for a token

> **Vulnerability classes:** vuln/theft · vuln/locked-funds · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63922-h-01-deprecated-safeapprove-usage-blocks-collateral-approval.md -->

## Root cause

After the first successful collateral supply for a token, every later executeOperation() for that token reverts inside the deprecated SafeERC20.safeApprove (non-zero-to-non-zero allowance), permanently bricking collateral supply through this path (liveness DoS; 100e18 collateral un-suppliable per call, no funds stolen).

```solidity
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: identical loop but with forceApprove() (the report's fix),
// which resets a non-zero allowance instead of reverting on it.
```

## Why it's exploitable here

After the first successful collateral supply for a token, every later executeOperation() for that token reverts inside the deprecated SafeERC20.safeApprove (non-zero-to-non-zero allowance), permanently bricking collateral supply through this path (liveness DoS; 100e18 collateral un-suppliable per call, no funds stolen).

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  S1["VULN step 2"]
  S2["VULN step 3"]
  H["After the first successful collateral supply for a token, every later "]
  S0 --> S1
  S1 --> S2
  S2 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L362** — VULN step 1: deprecated safeApprove reverts once allowance is non-zero, permanently bricking collateral supply for this token
2. **L364** — VULN step 2: deprecated safeApprove reverts once allowance is non-zero, permanently bricking collateral supply for this token
3. **L365** — VULN step 3: deprecated safeApprove reverts once allowance is non-zero, permanently bricking collateral supply for this token

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63922-h-01-deprecated-safeapprove-usage-blocks-collateral-approval_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **After the first successful collateral supply for a token, every later executeOperation() for that token reverts inside the deprecated SafeER**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
