# GTE: order.prevOrderId written to a memory copy, never persisted

> **Vulnerability classes:** vuln/locked-funds
>
> **Reproduction:** a faithful minimal reproduction of the vulnerable finding — the vulnerable function is reproduced **verbatim** (marked `@>`) with faithful minimal doubles; local deploy, no fork.

<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/64869-h-01-order-double-linked-list-is-broken-because-orderprevord.md -->

## Root cause

order.prevOrderId = tailOrder.id is set on a MEMORY copy of the order and never written back to storage, so every order's back-pointer is null; removing the tail forces limit.tailOrder = null, corrupting the doubly-linked list and breaking subsequent order placement.

```solidity
        } else {
            Order storage tailOrder = self.orders[limit.tailOrder];
            tailOrder.nextOrderId = order.id;
            order.prevOrderId = tailOrder.id; // @> written to the MEMORY copy of `order`; never persisted to self.orders[order.id]
            limit.tailOrder = order.id;
        }
```

## Why it's exploitable here

order.prevOrderId is written to a MEMORY copy in Book._updateLimitPostOrder and never persisted, so every order's storage back-pointer is null; removing the tail order then forces the limit's headOrder AND tailOrder to null while a live order still occupies the limit, corrupting the CLOB doubly-linked list and DoS-ing add/remove on that limit.

## Attack path

```mermaid
flowchart TD
  S0["Persist order to storage"]
  S1["Back-pointer set on memory copy"]
  S2["Remove order from book"]
  S3["Select limit for order side"]
  S4["Add order to book"]
  H["order.prevOrderId = tailOrder.id is set on a MEMORY copy of the order "]
  S0 --> S1
  S1 --> S2
  S2 --> S3
  S3 --> S4
  S4 --> H
```

## Marked-line walkthrough (Playground)

The EVM Playground pins each step to the exact executed source line in `0x8ea53755a6…`:

1. **L148** — Persist order to storage: Writes the order into storage here — but the back-pointer set later on a memory copy happens after this and is never saved.
2. **L161** — Back-pointer set on memory copy: Sets `prevOrderId` on a MEMORY copy of the order that is never written back to storage, so every order's stored back-pointer stays null.
3. **L170** — Remove order from book: Removal relies on the back-pointers; with them all null, deleting the tail nulls both head and tail, corrupting the linked list.
4. **L179** — Select limit for order side: Picks the bid or ask limit bucket that holds this order's price level.
5. **L210** — Add order to book: Setup: takes `order` by memory copy — the same copy-then-mutate pattern that loses the back-pointer write.
6. **L319** — View ask order count: Setup: read-only helper returning how many orders rest at an ask price level.
7. **L340** — View an order's back-pointer: Setup: exposes `prevOrderId`, which reads null for every order because it was never persisted.

## PoC

Registry (Foundry, local deploy — verbatim vulnerable source + harm-asserting test + negative control):

```bash
cd 64869-h-01-order-double-linked-list-is-broken-because-orderprevord_exp
forge test -vvv
```

The browser Playground replays the same synthetic opcode-for-opcode and measures the harm: **order.prevOrderId is written to a MEMORY copy in Book._updateLimitPostOrder and never persisted, so every order's storage back-pointer is null; removing the tail order then forces the limit's headOrder AND tailOrder to null while a live order still occupies the limit, corrupting the CLOB doubly-linked list and DoS-ing add/remove on that limit.**. Both gates are green (registry `forge test` PASS + Playground `_verify-poc` **VERDICT: PASS**).
