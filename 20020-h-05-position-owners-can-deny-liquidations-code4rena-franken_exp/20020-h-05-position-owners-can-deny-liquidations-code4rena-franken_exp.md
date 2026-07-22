# Frankencoin — Position owners can deny liquidations (unbounded price overflow)

> **Vulnerability classes:** vuln/arithmetic/overflow-dos · vuln/access-control/unbounded-parameter · vuln/loss-of-funds/frozen-funds

> **Reproduction:** a self-contained Foundry PoC that compiles & runs in an
> isolated project with **only `forge-std`** — no fork, no RPC, no `anvil_state`.
> Full trace: [output.txt](output.txt). PoC:
> [test/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.sol](test/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.sol).

<!-- non-defihacklabs -->
<!-- source-auditvault: https://github.com/Auditware/AuditVault/blob/main/findings/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.md -->
<!-- date: 2023-04 -->

---

## Key info

| | |
|---|---|
| **Impact** | **HIGH** — a position owner sets the liquidation price to `type(uint256).max`, overflowing every challenge-resolution multiplication. No bid can avert the challenge and `MintingHub.end` can never settle it, so the challenger's escrowed collateral is locked in the hub forever and no reward is paid |
| **Protocol** | [Frankencoin](https://frankencoin.com) — a collateralized, decentralized stablecoin (ZCHF) with an auction-based liquidation mechanism |
| **Vulnerable code** | `Position.adjustPrice` (unbounded `price`) → `price * _collateralAmount` in `tryAvertChallenge` and `_mulD18(price, _size)` in `notifyChallengeSucceeded` both overflow |
| **Bug class** | Unbounded owner-set parameter → checked-arithmetic overflow → permanent denial of liquidation (funds frozen) |
| **Finding** | Code4rena — Frankencoin, 2023-04 · #20020 · reporter **JGcarv** |
| **Report** | [code4rena.com/reports/2023-04-frankencoin](https://code4rena.com/reports/2023-04-frankencoin) |
| **Source** | [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.md) |
| **Status** | Audit finding — caught in review (not exploited on-chain). Confirmed by the Frankencoin team (*"Ouch, this is a good one."*) and judged HIGH. Reproduced here as a standalone local PoC. |
| **Compiler** | `^0.8.24` (PoC) |

This is an **audit finding**, not a historical on-chain incident. The PoC keeps the
three blamed lines verbatim: the unbounded `price = newPrice` in `adjustPrice`, and
the two overflowing multiplications in `tryAvertChallenge` and
`notifyChallengeSucceeded`.

---

## TL;DR

1. A position owner can set the liquidation `price` arbitrarily high via
   `adjustPrice` (or the opening `_liqPrice`) — **there is no upper bound.**
2. Every challenge-resolution path multiplies `price` by a collateral amount:
   `price * _collateralAmount` in `tryAvertChallenge`, and `_mulD18(price, _size)`
   (i.e. `price * _size / 1e18`) in `notifyChallengeSucceeded`.
3. With `price = type(uint256).max` those products overflow, and Solidity 0.8
   checked arithmetic **reverts**.
4. So no bid can ever avert the challenge, and `MintingHub.end` can never settle
   it. The collateral a challenger escrowed when launching the challenge is
   **locked in the hub forever**, and the challenger gets no reward.
5. This denies liquidation entirely: the owner keeps their minted ZCHF and simply
   abandons the (now worthless) collateral, pushing the loss onto challengers.

---

## The vulnerable code

The unbounded price (verbatim, `Position.adjustPrice`):

```solidity
function adjustPrice(uint256 newPrice) public onlyOwner noChallenge {
    if (newPrice > price) {
        restrictMinting(3 days);
    } else {
        checkCollateral(collateralBalance(), newPrice);
    }
    price = newPrice; // @> no upper bound: can be type(uint256).max
    emitUpdate();
}
```

The averting-path overflow (verbatim, `Position.tryAvertChallenge`):

```solidity
} else if (_bidAmountZCHF * ONE_DEC18 >= price * _collateralAmount){ // @> price * amount overflows
```

The settlement-path overflow (verbatim, `Position.notifyChallengeSucceeded`):

```solidity
uint256 volumeZCHF = _mulD18(price, _size); // @> _mulD18 == price * _size / 1e18 -> price * _size overflows
```

---

## Root cause

The liquidation price is an owner-controlled value with no maximum, yet it is used
as a multiplicand in checked arithmetic across every path that resolves a
challenge. Setting it to `type(uint256).max` turns each of those multiplications
into a guaranteed revert, so the challenge mechanism — the protocol's only tool for
liquidating an under-collateralized position — becomes permanently inoperative for
that position.

## Preconditions

- Anyone can open a position and raise its price via `adjustPrice` (owner-only, but
  the owner is the attacker) — permissionless.
- The position is not expired (so `tryAvertChallenge` reaches the overflowing
  comparison rather than the "expired" early return).
- A challenger has escrowed collateral against the position (the value that becomes
  locked).

## Attack walkthrough

From [output.txt](output.txt) (two positions are used only because the browser PoC
cannot advance time — one with a zero challenge period so `end` is callable
immediately, one with an open window so a `bid` can be attempted):

1. The owner reprices both positions to `type(uint256).max` via `adjustPrice`.
2. A challenger escrows `1e18` collateral against each (`launchChallenge` pulls it
   into the hub).
3. `end` is called on the zero-period challenge. It first tries to return the
   escrow, then calls `notifyChallengeSucceeded`, where `_mulD18(price, _size)`
   overflows — reverting the whole `end` call and rolling back the return.
4. A `bid` is attempted on the open challenge; `tryAvertChallenge` overflows at
   `price * _collateralAmount`, so no bid can ever avert it.
5. **HARM:** both resolution paths revert permanently, and the challenger's full
   `2e18` escrow stays trapped in the hub with no way out. A control assertion
   shows that with a *sane* price the same `end` flow settles and returns the
   collateral — isolating the unbounded price as the root cause.

## Diagrams

```mermaid
flowchart TD
    A[Owner: adjustPrice = type(uint256).max] --> B[No upper bound enforced]
    B --> C[Challenger escrows collateral in hub via launchChallenge]
    C --> D{Resolve the challenge}
    D -->|bid| E["tryAvertChallenge: price * _collateralAmount"]
    D -->|end| F["notifyChallengeSucceeded: _mulD18(price, _size)"]
    E --> G[uint256 overflow -> revert]
    F --> H[uint256 overflow -> revert]
    G --> I[No bid can avert]
    H --> J[end() reverts -> escrow return rolled back]
    I --> K[Challenge unresolvable]
    J --> K
    K --> L[Challenger collateral locked in hub forever, no reward]
```

```mermaid
sequenceDiagram
    participant O as Owner (attacker)
    participant C as Challenger (victim)
    participant H as MintingHub
    participant P as Position
    O->>P: adjustPrice(type(uint256).max)
    C->>H: launchChallenge(pos, size)  [collateral escrowed]
    Note over H: end(): returnCollateral(...) then notifyChallengeSucceeded(...)
    H->>P: notifyChallengeSucceeded(...)
    P-->>H: revert (price * size overflow)
    Note over H: whole end() reverts -> escrow NOT returned
    Note over C,H: challenger collateral locked forever; liquidation denied
```

## Remediation

Enforce an upper bound on the liquidation price (and/or the per-adjustment change),
and restrict when a repriced position can be challenged so that a challenge can only
target a position that was once validly priced. This prevents an owner from moving
`price` into the range where the challenge-resolution arithmetic overflows.

## How to reproduce

```bash
cd ~/RustroverProjects/audits/evm-hack-registry/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken_exp
forge test -vvv
# Fully local — no fork, no RPC, no anvil_state required.
# Expected: both tests PASS:
#   test_maxPrice_locks_challenger_collateral       (attack: end + bid both revert, escrow locked)
#   test_sanePrice_end_settles_and_returns_collateral (control: sane price -> end settles)
```

PoC source: [test/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.sol](test/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.sol)
— the verbatim `adjustPrice`, `tryAvertChallenge`, and `notifyChallengeSucceeded`
lines plus the deny-liquidation attack and a control test.

> Note: two positions and specific challenge sizes are reduced-model scaffolding
> chosen so the harm is observable without advancing time in-browser. The three
> blamed lines and the overflow-on-max-price behavior are faithful; the exact
> `2e18` locked magnitude validates the model. The lock (challenger collateral
> frozen, liquidation denied) is the impact accepted by the judge.

---

*Reference: finding **#20020** by **JGcarv** in the [Code4rena Frankencoin audit (Apr 2023)](https://code4rena.com/reports/2023-04-frankencoin) · curated by [AuditVault](https://github.com/Auditware/AuditVault/blob/main/findings/20020-h-05-position-owners-can-deny-liquidations-code4rena-franken.md)*
