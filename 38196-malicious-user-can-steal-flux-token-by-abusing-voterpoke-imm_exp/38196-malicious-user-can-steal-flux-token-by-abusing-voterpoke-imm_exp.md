# Alchemix: A malicious veALCX holder pokes 3x in one epoch

> **Vulnerability classes:** vuln/unfair-mint
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/38196-malicious-user-can-steal-flux-token-by-abusing-voterpoke-imm.md -->

## Root cause

A malicious veALCX holder pokes 3x in one epoch, tripling unclaimedFlux via accrueFlux's unbounded accumulation, then claimFlux mints 3 FLUX (3x the fair 1e18 single-epoch entitlement, a 2e18 illegitimate over-mint) to the attacker EOA.

```solidity
    /// @dev Verbatim audited source (see VERBATIM marker above).
    function accrueFlux(uint256 _tokenId) external {
        require(msg.sender == voter, "not voter");
        uint256 amount = IVotingEscrow(veALCX).claimableFlux(_tokenId);
        unclaimedFlux[_tokenId] += amount; // @> no claimed/per-epoch tracking: repeated pokes accumulate claimableFlux without bound
    }
```

## Why it's exploitable here

A malicious veALCX holder pokes 3x in one epoch, tripling unclaimedFlux via accrueFlux's unbounded accumulation, then claimFlux mints 3 FLUX (3x the fair 1e18 single-epoch entitlement, a 2e18 illegitimate over-mint) to the attacker EOA.

## Attack path

```mermaid
flowchart TD
  S0["Setup: token name"]
  S1["Internal FLUX mint helper"]
  S2["Setup: ERC20 helper returns true"]
  S3["Setup: wire the Voter address"]
  S4["Claim reads inflated FLUX amount"]
  H["A malicious veALCX holder pokes 3x in one epoch, tripling unclaimedFlu"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L41** — Setup: token name: Setup: constructor wiring assigns the FLUX token's `name`.
2. **L45** — Internal FLUX mint helper: Setup: `_mint` is the routine that will over-issue FLUX once the claim reads the inflated, accumulated balance.
3. **L58** — Setup: ERC20 helper returns true: Setup: standard ERC20 boilerplate returning `true` — plumbing of the FLUX token.
4. **L105** — Setup: wire the Voter address: Setup: `setVoter` links the escrow to the Voter whose unguarded `poke` drives the repeated accrual.
5. **L126** — Claim reads inflated FLUX amount: Root cause: this reads `claimableFlux`, which `accrueFlux` let accumulate with no epoch cap — after 3 pokes it returns 3x the fair amount, then minted.
6. **L132** — updateFlux adjusts accrual: `updateFlux` is part of the accrual bookkeeping the repeated pokes exploit to run `unclaimedFlux` up.
7. **L164** — unclaimedFlux accumulator storage: `unclaimedFlux` is the per-token accumulator that grows unbounded across pokes, holding the tripled claimable amount.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 38196-malicious-user-can-steal-flux-token-by-abusing-voterpoke-imm_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A malicious veALCX holder pokes 3x in one epoch, tripling unclaimedFlux via accrueFlux's unbounded accumulation, then claimFlux mints 3 FLUX**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
