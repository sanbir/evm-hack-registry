# YuzuUSD: A withdrawer who opens a redeem order is paid the fixed pre-yield amount (100e18) at final

> **Vulnerability classes:** vuln/logic
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62756-h-01-pending-withdrawals-in-yuzuilp-contract-are-not-conside.md -->

## Root cause

A withdrawer who opens a redeem order is paid the fixed pre-yield amount (100e18) at finalize, while their still-counted shares earned 50e18 of yield during the pending window; that 50e18 leaks to the remaining holder (B's redeemable rises 150e18->200e18), so the withdrawer loses their rightful pro-rata yield.

```solidity
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }

        uint256 assets = previewRedeemOrder(tokens); // @> asset value FIXED at current pre-yield price; the redeemed shares are NOT excluded from totalAssets()/totalSupply(), so they keep accruing yield the withdrawer never receives
        address caller = _msgSender();
        uint256 orderId = _createRedeemOrder(caller, receiver, owner, tokens, assets);
```

## Why it's exploitable here

A withdrawer who opens a redeem order is paid the fixed pre-yield amount (100e18) at finalize, while their still-counted shares earned 50e18 of yield during the pending window; that 50e18 leaks to the remaining holder (B's redeemable rises 150e18->200e18), so the withdrawer loses their rightful pro-rata yield.

## Attack path

```mermaid
flowchart TD
  S0["Total assets from balance"]
  S1["Preview deposit shares"]
  S2["Convert shares to assets"]
  S3["Open a redeem order"]
  S4["Lock payout before yield accrues"]
  H["A withdrawer who opens a redeem order is paid the fixed pre-yield amou"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L106** — Total assets from balance: Total assets equal the vault's live asset balance, which grows as yield accrues over time.
2. **L123** — Preview deposit shares: Setup: view converting a deposit amount into the shares it would mint.
3. **L128** — Convert shares to assets: Converts a share amount into assets at the vault's current pool ratio.
4. **L145** — Open a redeem order: Entry point where a holder queues a redeem order to be finalized later, opening a pending window.
5. **L158** — Lock payout before yield accrues: Root cause: freezes the payout at the current pre-yield value; the escrowed shares keep earning yield during the pending window that the withdrawer never receives.
6. **L160** — Store order with frozen amount: Records the order with that frozen `assets` figure, so finalize later pays only the stale pre-yield amount.
7. **L176** — Debit owner's shares to escrow: Debits the redeeming shares from the owner as the order is escrowed, yet they stay counted and keep accruing yield that leaks to remaining holders.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62756-h-01-pending-withdrawals-in-yuzuilp-contract-are-not-conside_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A withdrawer who opens a redeem order is paid the fixed pre-yield amount (100e18) at finalize, while their still-counted shares earned 50e18**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
