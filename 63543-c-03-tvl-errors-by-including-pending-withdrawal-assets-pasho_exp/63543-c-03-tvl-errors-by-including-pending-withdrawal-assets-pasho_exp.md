# Elytra: getTotalAssetTVL keeps counting the unstaking-vault backing of a pending withdrawal whose 

> **Vulnerability classes:** vuln/theft · vuln/price
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/63543-c-03-tvl-errors-by-including-pending-withdrawal-assets-pasho.md -->

## Root cause

getTotalAssetTVL keeps counting the unstaking-vault backing of a pending withdrawal whose elyHYPE shares were already burned, spiking price from 1.5 to 3.75; the attacker redeems 4e18 elyHYPE for 15e18 HYPE (vs 6e18 fair), draining the 9e18 reserve owed to the pending withdrawer, who is then paid 0.

```solidity
        uint256 strategyAllocated = assetsAllocatedToStrategies[asset];
        uint256 unstakingVaultBalance = _getUnstakingVaultBalance(asset);

        return poolBalance + strategyAllocated + unstakingVaultBalance; // @> counts unstaking-vault backing of already-burned pending shares → inflates TVL/price
    }

```

## Why it's exploitable here

getTotalAssetTVL keeps counting the unstaking-vault backing of a pending withdrawal whose elyHYPE shares were already burned, spiking price from 1.5 to 3.75; the attacker redeems 4e18 elyHYPE for 15e18 HYPE (vs 6e18 fair), draining the 9e18 reserve owed to the pending withdrawer, who is then paid 0.

## Attack path

```mermaid
flowchart TD
  S0["TVL counts pending-withdrawal backing"]
  S1["Fetch unstaking vault address"]
  S2["Unstaking vault helper"]
  S3["Resolve vault from config"]
  S4["Withdrawal burns shares, reserves assets"]
  H["getTotalAssetTVL keeps counting the unstaking-vault backing of a pendi"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xe3a787a4e4…`:

1. **L177** — TVL counts pending-withdrawal backing: Root cause: TVL adds `unstakingVaultBalance`, which backs already-burned pending withdrawals, double-counting it and spiking share price.
2. **L181** — Fetch unstaking vault address: Setup: resolves the unstaking vault's address from config so its balance can be read into TVL.
3. **L194** — Unstaking vault helper: Setup: `_vault()` returns the typed `ElytraUnstakingVault` handle used by the withdrawal flow.
4. **L195** — Resolve vault from config: Setup: looks up the unstaking vault contract by its registry key and casts it to the typed interface.
5. **L207** — Withdrawal burns shares, reserves assets: `requestWithdrawal` burns elyHYPE shares and reserves backing assets in the unstaking vault — the balance TVL keeps double-counting.
6. **L217** — Attacker redeems at inflated price: The attacker calls `withdraw`, redeeming elyHYPE at the inflated 3.75 price the TVL double-count produced.
7. **L224** — Transfer out inflated payout: Sends the over-valued `assetsOut` to the attacker, draining the reserve owed to the pending withdrawer, who is then paid 0.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 63543-c-03-tvl-errors-by-including-pending-withdrawal-assets-pasho_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **getTotalAssetTVL keeps counting the unstaking-vault backing of a pending withdrawal whose elyHYPE shares were already burned, spiking price **. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
