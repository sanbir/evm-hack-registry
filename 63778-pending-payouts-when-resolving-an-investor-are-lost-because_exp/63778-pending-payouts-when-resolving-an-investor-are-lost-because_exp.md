# Remora: resolveUser migrates a departing investor's pending dividend into DividendManager._resolve

> **Vulnerability classes:** vuln/locked-funds · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63778-pending-payouts-when-resolving-an-investor-are-lost-because.md -->

## Root cause

resolveUser migrates a departing investor's pending dividend into DividendManager._resolvedPay[newAddress], which no function ever reads, so P=1,000 USDC (1000000000 units) stays permanently locked in the manager and the new address can never claim it; a second resolve to the same address also overwrites and destroys the prior amount.

```solidity

    // ── VERBATIM vulnerable function from the finding ──────────────────────────
    function _resolvePay(address oldAddress, address newAddress) internal {
        _getHolderManagementStorage()._resolvedPay[newAddress] = SafeCast.toUint128(_claimPayout(oldAddress)); // @> migrates payout into _resolvedPay[newAddress], but NO function ever reads it -> funds locked; also overwrites any prior value
        emit PaymentResolved(oldAddress, newAddress);
    }
```

## Why it's exploitable here

resolveUser migrates a departing investor's pending dividend into DividendManager._resolvedPay[newAddress], which no function ever reads, so P=1,000 USDC (1000000000 units) stays permanently locked in the manager and the new address can never claim it; a second resolve to the same address also overwrites and destroys the prior amount.

## Attack path

```mermaid
flowchart TD
  S0["Token symbol storage"]
  S1["Holder-management storage accessor"]
  S2["Clear the holder's pending dividend"]
  S3["Migrate payout to new address"]
  S4["Write into a mapping nothing reads"]
  H["resolveUser migrates a departing investor's pending dividend into Divi"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L48** — Token symbol storage: Setup: token metadata field, part of the same security-token contract state layout.
2. **L107** — Holder-management storage accessor: Setup: returns the storage struct holding each investor's `pending` dividends and the `_resolvedPay` mapping written on resolve.
3. **L116** — Clear the holder's pending dividend: `_claimPayout` zeroes the old holder's `pending` balance and returns it — this returned amount is what resolve then misfiles.
4. **L121** — Migrate payout to new address: `_resolvePay` moves a departing investor's pending dividend from `oldAddress` to their `newAddress` during a resolve.
5. **L122** — Write into a mapping nothing reads: Root cause: the migrated payout is stored in `_resolvedPay[newAddress]`, which no claim function ever reads, so the 1,000 USDC is permanently locked.
6. **L149** — Read-only view of resolved pay: `resolvedPayOf` merely views `_resolvedPay`; there is no matching function to withdraw it, confirming the funds have no exit.
7. **L161** — Emit payment-resolved event: Setup: emits `PaymentResolved` on the migration; the event fires even though the moved dividend is now unclaimable.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63778-pending-payouts-when-resolving-an-investor-are-lost-because_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **resolveUser migrates a departing investor's pending dividend into DividendManager._resolvedPay[newAddress], which no function ever reads, so**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
