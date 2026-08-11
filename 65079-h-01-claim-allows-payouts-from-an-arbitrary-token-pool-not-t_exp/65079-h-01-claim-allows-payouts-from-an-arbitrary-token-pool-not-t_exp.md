# Abster Freefall: A player who staked a game in the small-pool token (USDC) claims the payout out of the lar

> **Vulnerability classes:** vuln/theft · vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65079-h-01-claim-allows-payouts-from-an-arbitrary-token-pool-not-t.md -->

## Root cause

A player who staked a game in the small-pool token (USDC) claims the payout out of the large-pool token (WETH) — Freefall.claim reads the pool and pays from the caller-supplied _tokenAddress without checking it equals game.tokenAddress — draining 100 WETH (the entire pool) to the attacker EOA who never wagered WETH.

```solidity

    // ─── verbatim vulnerable claim() core (finding 65079, Freefall.sol#L219) ───
    function claim(address _tokenAddress, string calldata _gameId) external {
        Pool storage pool = liquidityPool[_tokenAddress]; // @> pool chosen from caller-supplied _tokenAddress, never checked == game.tokenAddress
        uint256 onChainGameId = offChainGameIdToOnChainGameId[_gameId];
        Game storage game = games[onChainGameId];
```

## Why it's exploitable here

A player who staked a game in the small-pool token (USDC) claims the payout out of the large-pool token (WETH) — Freefall.claim reads the pool and pays from the caller-supplied _tokenAddress without checking it equals game.tokenAddress — draining 100 WETH (the entire pool) to the attacker EOA who never wagered WETH.

## Attack path

```mermaid
flowchart TD
  S0["VULN step 1"]
  H["A player who staked a game in the small-pool token (USDC) claims the p"]
  S0 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xce01759b82…`:

1. **L126** — VULN step 1: pool chosen from caller-supplied _tokenAddress, never checked == game.tokenAddress

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65079-h-01-claim-allows-payouts-from-an-arbitrary-token-pool-not-t_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **A player who staked a game in the small-pool token (USDC) claims the payout out of the large-pool token (WETH) — Freefall.claim reads the po**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
