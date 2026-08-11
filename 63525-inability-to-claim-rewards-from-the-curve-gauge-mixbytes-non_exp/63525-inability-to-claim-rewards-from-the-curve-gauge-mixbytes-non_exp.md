# Notional Finance: Curve-gauge LP stakers receive 0 accrued CRV on exit because _unstakeLpTokens calls withdr

> **Vulnerability classes:** vuln/locked-funds · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63525-inability-to-claim-rewards-from-the-curve-gauge-mixbytes-non.md -->

## Root cause

Curve-gauge LP stakers receive 0 accrued CRV on exit because _unstakeLpTokens calls withdraw(poolClaim) without the _claim_rewards flag (defaults False) and no reward-manager claim path exists, so 1000 CRV stays locked in the gauge, undelivered.

```solidity
            bool success = IConvexRewardPool(CONVEX_REWARD_POOL).withdrawAndUnwrap(poolClaim, false);
            require(success);
        } else {
            ICurveGauge(CURVE_GAUGE).withdraw(poolClaim); // @> no _claim_rewards flag (defaults False) & no reward-manager claim path -> accrued CRV never delivered on unstake
        }
    }
```

## Why it's exploitable here

Curve-gauge LP stakers receive 0 accrued CRV on exit because _unstakeLpTokens calls withdraw(poolClaim) without the _claim_rewards flag (defaults False) and no reward-manager claim path exists, so 1000 CRV stays locked in the gauge, undelivered.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["Curve-gauge LP stakers receive 0 accrued CRV on exit because _unstakeL"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xe3a787a4e4…`:

1. **L193** — VULN step 1: no _claim_rewards flag (defaults False) & no reward-manager claim path -> accrued CRV never delivered on unstake

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63525-inability-to-claim-rewards-from-the-curve-gauge-mixbytes-non_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Curve-gauge LP stakers receive 0 accrued CRV on exit because _unstakeLpTokens calls withdraw(poolClaim) without the _claim_rewards flag (def**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
