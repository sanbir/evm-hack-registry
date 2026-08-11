# Super DCA: An attacker's unlisted duplicate DCA/USDC V4 pool (same hook) triggers the shared per-toke

> **Vulnerability classes:** vuln/theft · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63420-h-2-attackers-will-steal-rewards-from-legitimate-pools-by-ma.md -->

## Root cause

An attacker's unlisted duplicate DCA/USDC V4 pool (same hook) triggers the shared per-token reward accrual and captures the community donation, stealing 500e18 DCA (the community half of USDC's 1000e18 reward bucket) to the attacker EOA while the legitimately-listed pool receives 0.

```solidity
            : Currency.unwrap(key.currency0);

        // Calculate pending rewards from the external staking contract
        uint256 rewardAmount = staking.accrueReward(otherToken); // @> per-token bucket accrued (and reset) for ANY pool incl. an unlisted duplicate; NO pool-legitimacy check
        if (rewardAmount == 0) return;

```

## Why it's exploitable here

An attacker's unlisted duplicate DCA/USDC V4 pool (same hook) triggers the shared per-token reward accrual and captures the community donation, stealing 500e18 DCA (the community half of USDC's 1000e18 reward bucket) to the attacker EOA while the legitimately-listed pool receives 0.

## Attack path

```mermaid
flowchart TD
  S0["Position struct tick field"]
  S1["PoolManager sync interface"]
  S2["PoolManager settle interface"]
  S3["Route beforeAddLiquidity hook"]
  S4["Distribute and settle rewards"]
  H["An attacker's unlisted duplicate DCA/USDC V4 pool (same hook) triggers"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xe3a787a4e4…`:

1. **L55** — Position struct tick field: Setup: a Uniswap V4 position struct field (`tickUpper`) used by the hook's liquidity handling.
2. **L60** — PoolManager sync interface: Setup: declares the V4 PoolManager `sync` call used when settling token deltas.
3. **L61** — PoolManager settle interface: Setup: declares the V4 `settle` call that finalizes token payments in the hook flow.
4. **L263** — Route beforeAddLiquidity hook: Dispatches the add-liquidity hook — invoked for ANY pool sharing this hook, including the attacker's unlisted duplicate.
5. **L313** — Distribute and settle rewards: Handles reward distribution and settlement for the triggering pool, keyed only by the pool's tokens.
6. **L324** — Accrue reward by token only: Root cause: reward accrues for `otherToken` without verifying the pool is the registered/listed one, so an unlisted duplicate pool captures it.
7. **L366** — Return hook selector: Returns the expected hook selector to the PoolManager, completing the attacker-triggered add-liquidity callback.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63420-h-2-attackers-will-steal-rewards-from-legitimate-pools-by-ma_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An attacker's unlisted duplicate DCA/USDC V4 pool (same hook) triggers the shared per-token reward accrual and captures the community donati**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
