# NLX Oracle: multiple in-block price fetches enable risk-free arbitrage

**Protocol:** NLX (a fork of GMX-synthetics) · **Auditor:** Halborn · **Severity:** High
**AuditVault:** [#50882](https://github.com/Auditware/AuditVault/blob/main/findings/50882-multiple-price-fetches-leading-to-arbitrage-in-oracle-implem.md) · **Report:** <https://www.halborn.com/audits/coredao/nlx>
**Vulnerable source:** `src/nlx/contracts/oracle/Oracle.sol` — `_setPricesFromPriceFeeds` (L321-L362) / `_getPriceFeedPrice` (L283-L313)
**Fix commit:** [nlx-synthetics `a2f22a0`](https://github.com/NLX-Protocol/nlx-synthetics/commit/a2f22a08fa824131d9f88fdff1e23684ad84b0db) · **Family:** [gmx-io/gmx-synthetics](https://github.com/gmx-io/gmx-synthetics)

## Root cause

`Oracle.setPrices()` is the keeper entrypoint that prices every protocol action. It calls
`_setPricesFromPriceFeeds`, which:

```solidity
// Oracle.sol L321-L330 (unmodified, vendored under src/nlx/)
function _setPricesFromPriceFeeds(..., bytes[] memory pythUpdateData) internal {
    uint updateFee = pyth.getUpdateFee(pythUpdateData);
    require(updateFee <= msg.value, "not enough funds to update price feeds");
    pyth.updatePriceFeeds{value: updateFee}(pythUpdateData);   // caller supplies the update blob
    for (uint256 i; i < tokens.length; i++) {
        (bool hasPriceFeed, uint256 price) = _getPriceFeedPrice(dataStore, token); // reads pyth.getPrice
        ...
        _setPrimaryPrice(token, priceProps);
    }
}
```

The caller supplies `pythUpdateData` and the oracle applies **whichever** price that blob decodes to,
with the only freshness check being a coarse `heartbeatDuration` (1 day). Pyth publishes a new signed
price roughly every 400ms, so at any moment there are **several valid, signed prices** for the same feed.
Nothing pins the price used within a block to a single reference. A keeper (or anyone who controls order
execution ordering) can therefore run `setPrices → action → clearAllPrices → setPrices → action` inside a
**single transaction** and settle two actions at **two different valid prices** — a risk-free arbitrage /
backrun against the other side of the trade.

The reported on-chain evidence ([basescan `0x0e0c22…b51b95`](https://basescan.org/tx/0x0e0c22e5996ae58bbff806eba6d51e8fc773a3598ef0e0a359432e08f0b51b95))
shows exactly this: within one tx, `updatePriceFeeds` was invoked twice and two distinct prices were read —
`226646416525` (publishTime `1706358779`) and `226649088828` (publishTime `1706358790`).

## What the PoC does (real audited code, local deploy)

The PoC deploys the **real, unmodified** NLX `Oracle` plus its real dependency graph (`RoleStore`,
`DataStore`, `EventEmitter`, `OracleStore`, `Keys`, `Precision`, `Price`) — no stubbing of the vulnerable
consumer. The only non-audited pieces are (1) a minimal, honest `ControlledPyth` implementing the real
`IPyth` interface (`updatePriceFeeds` records whatever price the signed blob carries; `getPrice` returns it —
signature verification is external to the bug), and (2) a minimal `MiniERC20` + a thin `CashSettledLong`
venue that settles both legs off `oracle.getPrimaryPrice`, exactly as a GMX-style market does.

Numbers (with `priceFeedMultiplier = 1e30`, so `adjustedPrice == raw pyth price`):

| Step | Call | Recorded primary price |
|------|------|------------------------|
| Leg 1 | `oracle.setPrices(pythBlob_A)` → `openLong(size)` | `226,646,416,525` |
| — | `oracle.clearAllPrices()` | — |
| Leg 2 (same tx) | `oracle.setPrices(pythBlob_B)` → `closeLong()` | `226,649,088,828` |

Both legs execute in **one transaction**. The venue pays the long
`size * (B − A) = 1,000,000 * (226,649,088,828 − 226,646,416,525) = 2,672,303,000,000` USD out of the LP
reserve — for zero risk. If the oracle had returned a single consistent per-block price, entry == exit and
the profit would be **0**, so the harm is produced entirely by the oracle bug.

**Asserted harm:** attacker USD balance `+2,672,303,000,000`; LP reserve `−2,672,303,000,000`; and the same
token recorded two distinct primary prices in one tx (`226,646,416,525 != 226,649,088,828`).

```mermaid
sequenceDiagram
    actor K as Keeper / attacker
    participant O as NLX Oracle (real)
    participant P as Pyth feed
    participant V as CashSettledLong (LP)
    K->>O: setPrices(pythBlob_A)  [valid @ t]
    O->>P: updatePriceFeeds(A) ; getPrice()
    O-->>K: primaryPrice = 226,646,416,525
    K->>V: openLong(size)  @ price A
    K->>O: clearAllPrices()
    Note over K,O: same transaction
    K->>O: setPrices(pythBlob_B)  [valid @ t+11s]
    O->>P: updatePriceFeeds(B) ; getPrice()
    O-->>K: primaryPrice = 226,649,088,828
    K->>V: closeLong()  @ price B
    V-->>K: pay size*(B-A) = 2,672,303,000,000 USD
```

## Reproduce

```bash
_shared/run-poc/run_poc.sh 50882-multiple-price-fetches-leading-to-arbitrage-in-oracle-implem_exp -vvvvv
```

Expected: `[PASS] test_multi_fetch_arbitrage_drains_counterparty`.

## Fix

Pin the price used across an action/block to a single reference and bound in-block deviation (the CoreDAO
team added exactly such checks in `a2f22a0`): reject a second feed read that deviates beyond a threshold
within the same block, or cache the first-fetched price for the duration of the action.
