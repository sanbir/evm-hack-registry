# GTE: Non-strict crossing check traps min-tick backstop bids

> **Vulnerability classes:** vuln/locked-funds · vuln/price
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/64835-h-02-backstop-bid-side-frozen-by-tick-size-constraint-code4r.md -->

## Root cause

if (ds.getBestAsk() <= newOrder.price) uses a non-strict <=, so a backstop bid at the minimum tick is treated as crossing a min-tick ask and reverts, permanently freezing backstop bid placement at that level.

```solidity

    function _executeBuyOrder(Book storage ds, Order memory newOrder, TiF tif) internal {
        // if price crosses the book
        if (ds.getBestAsk() <= newOrder.price) { // @> CLOBLib.sol:231 non-strict `<=` traps the min-tick bid against a min-tick ask
            if (tif == TiF.MOC) revert PostOnlyOrderWouldBeFilled();
        }
```

## Why it's exploitable here

An attacker parks a SELL backstop maker (MOC) at price == tickSize, so getBestAsk() == tickSize; every legal backstop BID is a positive multiple of tickSize (minimum == tickSize == bestAsk), so the non-strict `getBestAsk() <= newOrder.price` post-only crossing rule always fires and reverts PostOnlyOrderWouldBeFilled — no backstop bid can ever be posted, permanently freezing the backstop bid side (liquidation-engine liveness DoS).

## Attack path

```mermaid
flowchart TD
  S0["Place a new order"]
  S1["Non-strict crossing check bug"]
  S2["Raise best-bid marker"]
  S3["Increment resting bid count"]
  S4["Execute a sell order"]
  H["if (ds.getBestAsk() <= newOrder.price) uses a non-strict <=, so a back"]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x671d353a77…`:

1. **L109** — Place a new order: Setup: entry point that posts `newOrder` into the book, routing bids through the post-only crossing check below.
2. **L124** — Non-strict crossing check bug: The post-only guard uses `<=`, so a bid priced exactly at the best ask (both at min tick) is wrongly seen as crossing and reverts; should be `<`.
3. **L128** — Raise best-bid marker: Updates `bidMax` when this bid is the new highest — code that never runs because the crossing check above reverts first.
4. **L129** — Increment resting bid count: Bumps `numBids` to record the posted bid, also unreachable for a min-tick backstop bid due to the revert.
5. **L132** — Execute a sell order: Setup: handles the SELL side; the attacker uses it to park a min-tick maker ask that pins `getBestAsk()` to `tickSize`.
6. **L151** — Place-order library overload: Setup: a second `placeOrder` overload in the order-book library.
7. **L224** — Initialize best-bid to zero: Setup: resets `bidMax` to its minimum value when the book is first created.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 64835-h-02-backstop-bid-side-frozen-by-tick-size-constraint-code4r_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **An attacker parks a SELL backstop maker (MOC) at price == tickSize, so getBestAsk() == tickSize; every legal backstop BID is a positive multiple of tickSize (minimum == tickSize == bestAsk), so the non-strict `getBestAsk() <= newOrder.price` post-only crossing rule always fires and reverts PostOnlyOrderWouldBeFilled — no backstop bid can ever be posted, permanently freezing the backstop bid side (liquidation-engine liveness DoS).**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
