# Music Protocol: redeeming a removed artist still pays 1,000 RECORD

> **Vulnerability classes:** vuln/logic/reward-calculation

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/59402-redeeming-does-not-discount-tokens-of-removed-artists-leadin.md -->
<!-- date: 2024-02 -->


`redeem` calls `_calcSinceLastPosition` only while the artist is still verified. After `removeArtist`, a full redeem zeroes the user's stake and leaves `artistStake` at 1,000. A 2,000 RECORD pot split by stake therefore mints 1,000 RECORD to the removed artist. The still-verified artist, who also has 1,000 stake, should have received the whole pot.

```solidity
if (live) {
    _calcSinceLastPosition(artist, _stake[artist][user].amount, false);
}
if (!live) skippedRedeem += _stake[artist][user].amount; // @> VULN
```

## Diagrams

```mermaid
flowchart TD
    A["Two verified artists each have 1,000 stake"] --> B["Owner removes the first artist"]
    B --> C["Staker redeems the full 1,000"]
    C --> D["artistStake is not reduced because the artist is not verified"]
    D --> E["getReward splits a 2,000 RECORD pot by the stale stake"]
    E --> F["Removed artist is minted 1,000 RECORD"]
```

## Impact

The removed artist receives 1,000 RECORD. Their `artistStake` is still 1,000. The fixed redeem subtracts the stake even after removal, so that artist is minted 0 and the active artist receives the full 2,000 RECORD.

## PoC

```bash
cd 59402-redeeming-does-not-discount-tokens-of-removed-artists-leadin_exp
forge test -vv
```

