# Attacker can stall Forta vault undelegations (locked funds via balance donation)

> **Vulnerability classes:** vuln/logic/incorrect-value-source · vuln/defi/griefing · vuln/math/underflow-dos
>
> **Reproduction:** the test deploys the REAL, unmodified audited `FortaStakingVault` + `InactiveSharesDistributor` (`NethermindEth/forta-staking-vault @ ce87cff`) and drives the two-step undelegation to completion. A 1-wei FORT donation to the cloned distributor permanently bricks completion and traps the delegated stake.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.md -->
<!-- date: 2024 -->

## Root cause

Undelegating a subject's stake is a two-step flow:

1. The operator calls [`FortaStakingVault.initiateUndelegate`](src/FortaStakingVault.sol#L201): it clones an `InactiveSharesDistributor`, transfers the vault's FortaStaking active shares to it, and arms the FortaStaking withdrawal delay.
2. After the delay, anyone calls [`FortaStakingVault.undelegate`](src/FortaStakingVault.sol#L233), which drives [`InactiveSharesDistributor.undelegate`](src/InactiveSharesDistributor.sol#L73) to pull the FORT back into the vault.

The distributor computes how much FORT it received the wrong way. `FortaStaking.withdraw` **returns** the exact amount released, but the distributor ignores that return value and instead reads its own token balance:

```solidity
// src/InactiveSharesDistributor.sol:74-75
_staking.withdraw(DELEGATOR_SCANNER_POOL_SUBJECT, _subject);
uint256 assetsReceived = _token.balanceOf(address(this)); // <-- attacker-manipulable
```

FORT is a plain ERC-20, so **anyone** can `transfer` FORT directly to the freshly-cloned distributor. That donation inflates `assetsReceived`, the distributor forwards the whole (stake + donation) to the vault, and the vault then executes:

```solidity
// src/FortaStakingVault.sol:259
_assetsPerSubject[subject] -= (afterWithdrawBalance - beforeWithdrawBalance);
```

`_assetsPerSubject[subject]` only ever tracked the real staked amount, so subtracting `stake + donation` underflows and reverts (Solidity 0.8 checked-arithmetic Panic `0x11`). Because `undelegate` is the only path that completes the withdrawal and it now reverts every time, the delegated FORT is stuck as an un-completable withdrawal inside FortaStaking — the vault (and thus its depositors) can never reclaim it. The stall is permanent: the donation already sits in the distributor, so retries keep reverting regardless of elapsed time. The operator can only paper over it by delegating *more* stake to bump `_assetsPerSubject`, and an attacker can immediately re-grief.

The fix ([PR #24](https://github.com/NethermindEth/forta-staking-vault/pull/24)) uses the value returned by `withdraw` instead of the distributor's balance.

## What is real vs modelled

- **Real, unmodified audited source (deployed and executed):** `FortaStakingVault`, `InactiveSharesDistributor`, `RedemptionReceiver`, plus the real `IFortaStaking`/`FortaStakingUtils`/`OperatorFeeUtils` and the real OpenZeppelin v5 (upgradeable) stack. Vendored under [`src/`](src/), byte-identical to commit `ce87cff`.
- **Modelled minimally:** the *external* FortaStaking core (out of audited scope). The project's own tests reach it only via a Polygon mainnet fork against the deployed `0xd286…6874`; for a local, fork-free deploy we use a faithful `MinimalFortaStaking` with real ERC-1155 share accounting, 1:1 stake↔shares (no slashing). Its `withdraw()` returns the true released amount — the bug is entirely in the audited contracts trusting a balance instead of that return value.

## Reproduction

```bash
_shared/run-poc/run_poc.sh 32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta_exp -vvvvv
```

Two tests in [`test/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta_exp.sol`](test/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta_exp.sol):

- `test_baseline_undelegate_succeeds_without_donation` — control: with no interference the vault reclaims its full 100 FORT (`_assetsPerSubject → 0`, distributor emptied). Isolates the donation as the sole cause.
- `test_attack_donation_permanently_stalls_undelegation` — attack: a 1-wei FORT donation makes `undelegate` revert with an arithmetic underflow; the vault reclaims `0`, the 100 FORT stays locked as an un-completable withdrawal in FortaStaking, and a later retry (even 1,000,000 s later) reverts again.

Expected result: `2 passed`.

## Attack sequence

```mermaid
sequenceDiagram
    participant Op as Operator
    participant V as FortaStakingVault (real)
    participant D as InactiveSharesDistributor (real, cloned)
    participant S as FortaStaking
    participant A as Attacker (any EOA)

    Op->>V: initiateUndelegate(subject, 100 FORT)
    V->>D: clone + transfer active shares
    V->>S: initiateWithdrawal (arm delay)
    A->>D: transfer 1 wei FORT (donation)
    Note over V,D: after delay, anyone may complete
    Op->>V: undelegate(subject)
    V->>D: undelegate()
    D->>S: withdraw() returns 100 FORT
    D->>D: assetsReceived = balanceOf = 100 + 1 wei\n(ignores withdraw return)
    D->>V: forward 100 FORT + 1 wei
    V->>V: _assetsPerSubject -= (100 + 1 wei)\nunderflow => REVERT
    Note over V,S: whole tx reverts; 100 FORT trapped\nas an un-completable withdrawal; permanent stall
```

## Sources

- [AuditVault finding #32467](https://github.com/Auditware/AuditVault/blob/main/findings/32467-attacker-can-stall-undelegations-openzeppelin-none-forta-sta.md)
- [Forta Staking Vault repo @ ce87cff](https://github.com/NethermindEth/forta-staking-vault/tree/ce87cffbf813e27cc83157933760b51fa44a1885)
- Vulnerable sources: [`src/FortaStakingVault.sol#L233`](src/FortaStakingVault.sol#L233), [`src/InactiveSharesDistributor.sol#L75`](src/InactiveSharesDistributor.sol#L75)
- [OpenZeppelin audit report](https://blog.openzeppelin.com/forta-staking-vault-audit) · [Fix PR #24](https://github.com/NethermindEth/forta-staking-vault/pull/24)
