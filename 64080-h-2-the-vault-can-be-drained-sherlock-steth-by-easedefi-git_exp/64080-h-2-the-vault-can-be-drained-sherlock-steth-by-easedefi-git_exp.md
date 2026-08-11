# stETH: The (untrusted) vault owner calls stakeNxm to deposit the vault's 1000 NXM into a Nexus st

> **Vulnerability classes:** vuln/theft
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/64080-h-2-the-vault-can-be-drained-sherlock-steth-by-easedefi-git.md -->

## Root cause

The (untrusted) vault owner calls stakeNxm to deposit the vault's 1000 NXM into a Nexus staking NFT the owner keeps, then withdraws the stake — draining the vault: vault wNXM/NXM go to 0 and the attacker EOA gains 1000 NXM.

```solidity
        nxm.approve(nxmMaster.getLatestAddress("TC"), _amount);

        IStakingPool pool = IStakingPool(_poolAddress);
        uint256 tokenId = pool.depositTo(_amount, _trancheId, _requestTokenId, address(this)); // @> no `require(stakingNFT.ownerOf(tokenId)==address(this))`: stake is credited to the attacker-owned requestTokenId, draining the vault

        // if new nft token is minted we need to keep track of
```

## Why it's exploitable here

The (untrusted) vault owner calls stakeNxm to deposit the vault's 1000 NXM into a Nexus staking NFT the owner keeps, then withdraws the stake — draining the vault: vault wNXM/NXM go to 0 and the attacker EOA gains 1000 NXM.

## Attack path

```mermaid
flowchart TD
  S0["Seed token-to-pool mapping"]
  S1["Stake vault NXM into Nexus pool"]
  S2["Record new staking NFT id"]
  S3["Load token's tranche list"]
  S4["Append tranche to token"]
  H["The (untrusted) vault owner calls stakeNxm to deposit the vault's 1000"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0xaf38a9c57e…`:

1. **L307** — Seed token-to-pool mapping: Setup: registers a seed staking NFT and its Nexus pool so the vault can later manage that stake.
2. **L322** — Stake vault NXM into Nexus pool: Root-cause bug: the untrusted vault owner calls `stakeNxm` to deposit the vault's NXM into a Nexus staking position, then withdraws it and drains the vault.
3. **L328** — Record new staking NFT id: Stores the minted Nexus staking token id — the position the owner later unstakes to pull the NXM out.
4. **L333** — Load token's tranche list: Reads the recorded tranches for this staking token id while bookkeeping the deposit.
5. **L337** — Append tranche to token: Records the tranche the vault's NXM was staked into for this token id.
6. **L353** — Token-to-pool mapping state: Setup: maps each staking NFT id to its Nexus pool.
7. **L354** — Token-to-tranches mapping state: Setup: maps each staking NFT id to the tranche ids its stake covers.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 64080-h-2-the-vault-can-be-drained-sherlock-steth-by-easedefi-git_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **The (untrusted) vault owner calls stakeNxm to deposit the vault's 1000 NXM into a Nexus staking NFT the owner keeps, then withdraws the stak**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
