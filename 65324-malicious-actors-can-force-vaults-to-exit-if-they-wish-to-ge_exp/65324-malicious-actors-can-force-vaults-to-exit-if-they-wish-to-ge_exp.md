# Statusl: An attacker registers many same-codehash vaults naming the victim as owner

> **Vulnerability classes:** vuln/locked-funds · vuln/reward-accounting
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/65324-malicious-actors-can-force-vaults-to-exit-if-they-wish-to-ge.md -->

## Root cause

An attacker registers many same-codehash vaults naming the victim as owner, inflating vaults[victim] until redeemRewards()/updateAccount() exceed the block gas limit, permanently locking the victim's 5,000 KARMA of accrued rewards (unclaimable unless a legitimate vault fully exits).

```solidity

        if (vaultOwners[vault] != address(0)) {
            revert StakeManager__VaultAlreadyRegistered();
        }

        vaultOwners[vault] = owner;
```

## Why it's exploitable here

An attacker registers many same-codehash vaults naming the victim as owner, inflating vaults[victim] until redeemRewards()/updateAccount() exceed the block gas limit, permanently locking the victim's 5,000 KARMA of accrued rewards (unclaimable unless a legitimate vault fully exits).

## Attack path

```mermaid
flowchart TD
  S0["Setup: reward index field"]
  S1["Setup: wire reward token"]
  S2["Attacker sets vault owner"]
  S3["Loop over account's vaults"]
  S4["Accrue multiplier points"]
  H["An attacker registers many same-codehash vaults naming the victim as o"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L133** — Setup: reward index field: Setup: declares `rewardIndex` in the vault's reward-accounting struct; state scaffolding.
2. **L180** — Setup: wire reward token: Setup: constructor stores `REWARD_TOKEN`, the KARMA rewards that will become locked for the victim.
3. **L197** — Attacker sets vault owner: `registerVault` records `vaultOwners[vault] = owner` from an attacker-supplied owner, attaching junk vaults to the victim's account.
4. **L218** — Loop over account's vaults: `updateAccount` iterates every vault owned by the account — the unbounded loop the attacker inflates until it exceeds block gas.
5. **L261** — Accrue multiplier points: Each iteration adds `accruedMP` to `totalMPStaked`, per-vault work that compounds the loop's gas cost.
6. **L302** — Return accrued points: Returns the vault's newly accrued multiplier points — computation repeated for every attacker-registered vault.
7. **L383** — Accrual math stub: Setup: `_calculateAccrual` is the harness stub standing in for the reward-accrual formula.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 65324-malicious-actors-can-force-vaults-to-exit-if-they-wish-to-ge_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An attacker registers many same-codehash vaults naming the victim as owner, inflating vaults[victim] until redeemRewards()/updateAccount() e**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
