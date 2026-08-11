# NUTS Finance: Because rebase()'s oldD>newD branch never syncs balances/totalSupply

> **Vulnerability classes:** vuln/theft · vuln/locked-funds · vuln/access-control
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62662-buffer-drainage-through-repeated-rebase-calls-due-to-stale-s.md -->

## Root cause

Because rebase()'s oldD>newD branch never syncs balances/totalSupply, 3 permissionless calls each recompute the same 100-unit gap and drain the poolToken buffer 3x (300 destroyed) vs 100 for one legitimate call — a value-destruction DoS of LP-holder-owned buffer value.

```solidity

        if (oldD == newD) {
            return 0;
        } else if (oldD > newD) {
            poolToken.removeTotalSupply(oldD - newD, true, true); // @> drains buffer but never updates `balances`/`totalSupply`, so the SAME gap re-triggers every call
            return 0;
```

## Why it's exploitable here

Because rebase()'s oldD>newD branch never syncs balances/totalSupply, 3 permissionless calls each recompute the same 100-unit gap and drain the poolToken buffer 3x (300 destroyed) vs 100 for one legitimate call — a value-destruction DoS of LP-holder-owned buffer value.

## Attack path

```mermaid
flowchart TD
  S0["Scale balance by feed decimals"]
  S1["Normalize balance by precision"]
  S2["oldD>newD branch never syncs state"]
  S3["Mark reserves non-empty"]
  S4["Newton loop for invariant D"]
  H["Because rebase()'s oldD>newD branch never syncs balances/totalSupply, "]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xbd4fd5a3ce…`:

1. **L187** — Scale balance by feed decimals: Divides each token's balance by its exchange-rate provider's decimals to bring it to a common scale.
2. **L188** — Normalize balance by precision: `_balances[i]` is rescaled by `precisions[i]` so all tokens share one fixed-point basis before computing the invariant `D`.
3. **L194** — oldD>newD branch never syncs state: Root-cause bug: this drain branch burns the D gap from the buffer but never writes back `balances`/`totalSupply`, so each repeat `rebase()` redrains the same gap.
4. **L219** — Mark reserves non-empty: Sets `allZero=false` once a non-zero reserve is seen while computing `D`.
5. **L230** — Newton loop for invariant D: Iterates up to 255 times to converge the StableSwap invariant `D` from the current balances.
6. **L273** — Wire pool token list: Setup: constructor stores the pool's `tokens` array.
7. **L274** — Wire per-token precisions: Setup: constructor stores each token's `precisions` scaling factor.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62662-buffer-drainage-through-repeated-rebase-calls-due-to-stale-s_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Because rebase()'s oldD>newD branch never syncs balances/totalSupply, 3 permissionless calls each recompute the same 100-unit gap and drain **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
