# Harmonix Finance: Any unprivileged EOA calls the unprotected public testFinalizeSettlement() to flip settlem

> **Vulnerability classes:** vuln/theft · vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63976-h-01-anyone-can-finalize-the-sale-early-via-testfinalizesett.md -->

## Root cause

Any unprivileged EOA calls the unprotected public testFinalizeSettlement() to flip settlementFinalized=true, after which every buyer's purchase() reverts permanently (both a fresh buyer and an existing buyer are frozen out); the sale is bricked and allocations locked at an attacker-chosen block. No theft; the blocked payment magnitude (1000e18) is marked to the SINK.

```solidity

    // ── VERBATIM vulnerable function from the finding (contracts/token_sales/
    //    HarTokenSale.sol#L182-L185). External, no owner check, no time check. ──
    function testFinalizeSettlement() external { // @> unprotected public finalize: any EOA flips settlementFinalized and permanently freezes purchase()
        require(!settlementFinalized, "Settlement: finalized");
        _finalizeSettlement();
```

## Why it's exploitable here

Any unprivileged EOA calls the unprotected public testFinalizeSettlement() to flip settlementFinalized=true, after which every buyer's purchase() reverts permanently (both a fresh buyer and an existing buyer are frozen out); the sale is bricked and allocations locked at an attacker-chosen block. No theft; the blocked payment magnitude (1000e18) is marked to the SINK.

## Attack path

```mermaid
flowchart TD
  S0["Reject zero-amount purchase"]
  S1["Unprotected public finalize function"]
  S2["Guard against double finalize"]
  S3["Internal settlement finalizer"]
  S4["Flip settlementFinalized flag"]
  H["Any unprivileged EOA calls the unprotected public testFinalizeSettleme"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L98** — Reject zero-amount purchase: `purchase()` rejects a zero buy amount — a normal buyer-path guard that early finalization will soon make unreachable.
2. **L106** — Unprotected public finalize function: Root-cause bug: `testFinalizeSettlement()` is `external` with no owner or access check, so any EOA can finalize the sale early.
3. **L107** — Guard against double finalize: The lone guard only blocks re-finalizing; it does nothing to stop an unauthorized first caller from triggering it.
4. **L111** — Internal settlement finalizer: Internal routine the unprotected wrapper calls to flip the sale into its finalized state.
5. **L112** — Flip settlementFinalized flag: Sets `settlementFinalized = true`; from here every buyer's `purchase()` reverts and allocations lock permanently.
6. **L123** — Owner state variable: Setup: the privileged `owner` that finalize should have been restricted to but never is.
7. **L128** — Per-buyer accepted allocations: Setup: tracks each buyer's accepted allocation, frozen at whatever block the attacker chose to finalize.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63976-h-01-anyone-can-finalize-the-sale-early-via-testfinalizesett_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **Any unprivileged EOA calls the unprotected public testFinalizeSettlement() to flip settlementFinalized=true, after which every buyer's purch**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
