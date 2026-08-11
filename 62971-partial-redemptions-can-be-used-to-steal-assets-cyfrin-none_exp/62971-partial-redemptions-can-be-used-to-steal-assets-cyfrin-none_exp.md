# Accountable: A partially-filled redeem controller re-requests; the never-decremented request.totalValue

> **Vulnerability classes:** vuln/theft · vuln/locked-funds · vuln/unfair-mint · vuln/price
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62971-partial-redemptions-can-be-used-to-steal-assets-cyfrin-none.md -->

## Root cause

A partially-filled redeem controller re-requests; the never-decremented request.totalValue inflates the averaged request.sharePrice, crediting ~500 assets for 200 shares worth 400 at true price 2, letting the controller drain the ~100 surplus base-assets from the pooled vault to the attacker EOA.

```solidity
        if (remainingShares == 0) {
            _delete(controller, requestId);
        } else {
            _queue.requests[requestId].shares = remainingShares; // @> totalValue is NOT decremented here — it stays inflated after a partial fill
        } // @audit the totalValue is not updated here.
    }
```

## Why it's exploitable here

A partially-filled redeem controller re-requests; the never-decremented request.totalValue inflates the averaged request.sharePrice, crediting ~500 assets for 200 shares worth 400 at true price 2, letting the controller drain the ~100 surplus base-assets from the pooled vault to the attacker EOA.

## Attack path

```mermaid
flowchart TD
  S0["Token name field"]
  S1["Share balances mapping"]
  S2["Submit redeem request"]
  S3["Branch on request-price mode"]
  S4["Reduce request by filled shares"]
  H["A partially-filled redeem controller re-requests; the never-decremente"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L40** — Token name field: Setup: declares the vault token's public `name`.
2. **L44** — Share balances mapping: Setup: standard `balanceOf` mapping for vault shares.
3. **L124** — Submit redeem request: `requestRedeem` records a controller's shares and price; re-calling it on a partial fill re-averages the stored price.
4. **L145** — Branch on request-price mode: Selects the `RequestPrice` path where the request's own `sharePrice` governs the payout.
5. **L171** — Reduce request by filled shares: `_reduce` computes `remainingShares` left after a partial fulfillment of the redeem request.
6. **L184** — Shares decremented, value kept: Root cause: writes back `remainingShares` but never decrements `request.totalValue`, so a re-request inflates the averaged `sharePrice`.
7. **L197** — Transfer surplus assets out: Pays `asset` to the recipient — the step that drains the ~100 surplus base-assets to the attacker.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62971-partial-redemptions-can-be-used-to-steal-assets-cyfrin-none_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A partially-filled redeem controller re-requests; the never-decremented request.totalValue inflates the averaged request.sharePrice, crediti**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
