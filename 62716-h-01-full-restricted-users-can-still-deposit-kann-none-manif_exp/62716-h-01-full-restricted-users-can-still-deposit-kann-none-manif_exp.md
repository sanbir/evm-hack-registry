# ManifestFinance: A FULL_RESTRICTED (blacklisted/sanctioned) caller successfully deposits and mints 1000e18 

> **Vulnerability classes:** vuln/unfair-mint
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/62716-h-01-full-restricted-users-can-still-deposit-kann-none-manif.md -->

## Root cause

A FULL_RESTRICTED (blacklisted/sanctioned) caller successfully deposits and mints 1000e18 vault shares to a clean receiver they control — a deposit that must revert with OperationNotAllowed instead succeeds, bypassing the compliance restriction; the fixed variant (caller-side FULL check) correctly reverts.

```solidity

    // ── VERBATIM from the finding ────────────────────────────────────────────
    function _update(address from, address to, uint256 value) internal override {
        if (hasRole(FULL_RESTRICTED_STAKER_ROLE, from) && to != address(0)) { // @> only `from`/`to` are gated; the mint path passes from=address(0), so a FULL_RESTRICTED msg.sender/caller is never checked → bypass
            revert OperationNotAllowed();
        }
```

## Why it's exploitable here

A FULL_RESTRICTED (blacklisted/sanctioned) caller successfully deposits and mints 1000e18 vault shares to a clean receiver they control — a deposit that must revert with OperationNotAllowed instead succeeds, bypassing the compliance restriction; the fixed variant (caller-side FULL check) correctly reverts.

## Attack path

```mermaid
flowchart TD
  S0["Mock underlying token"]
  S1["Test helper grants roles"]
  S2["Total supply accessor"]
  S3["Read sender balance"]
  S4["Store vault asset"]
  H["A FULL_RESTRICTED (blacklisted/sanctioned) caller successfully deposit"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L42** — Mock underlying token: Setup: declares the mock ERC20 that acts as the vault's underlying asset for the deposit test.
2. **L93** — Test helper grants roles: Setup: test-only helper used to grant compliance roles like `FULL_RESTRICTED_STAKER_ROLE` to an account.
3. **L118** — Total supply accessor: Setup: standard `totalSupply()` view returning the vault's minted share count.
4. **L134** — Read sender balance: Reads the `from` account's token balance inside the transfer/burn path before moving value.
5. **L169** — Store vault asset: Setup: the vault records its underlying asset address during construction.
6. **L194** — Deposit entry point: The `_deposit` core pulls assets from the caller and mints shares to the receiver — where the restriction should be enforced.
7. **L228** — Restriction checks wrong party: Root cause: the guard only blocks a restricted `from`, but a deposit mints (from is zero), so a sanctioned caller bypasses the compliance check and mints shares.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 62716-h-01-full-restricted-users-can-still-deposit-kann-none-manif_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A FULL_RESTRICTED (blacklisted/sanctioned) caller successfully deposits and mints 1000e18 vault shares to a clean receiver they control — a **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
