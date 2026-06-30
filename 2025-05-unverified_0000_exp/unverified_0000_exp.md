# Unverified BSC Victim Drain (mintTokens 0x88417d5c) — missing access control lets anyone sweep the contract's ERC20 balances
> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/access-control/missing-modifier · vuln/logic/missing-check
> **Reproduction:** the PoC compiles & runs in an isolated Foundry project at [this project folder](.). Full verbose trace: [output.txt](output.txt). The vulnerable contract at `0x000004A70f92f1B22de1201aF76C48365D5D0000` is **unverified on BscScan** (see `@Info` in the PoC), so the buggy function below is RECONSTRUCTED from the foundry `-vvvvv` call trace; every claim is anchored to a trace line.
---
## Key info
| | |
|---|---|
| **Loss** | 5,658.46 USD (reported in `@KeyInfo`; reproduced drained balances below) |
| **Vulnerable contract** | "Unverified Victim" — [`0x000004A70f92f1B22de1201aF76C48365D5D0000`](https://bscscan.com/address/0x000004A70f92f1B22de1201aF76C48365D5D0000) (code unverified) |
| **Attacker EOA** | [`0x1491B276528531AD3F41DbE9B00387ABaC55c114`](https://bscscan.com/address/0x1491B276528531AD3F41DbE9B00387ABaC55c114) |
| **Attack contract** | [`0x167d4A1658DD960B2945131Cd90ca4fdf0FAa242`](https://bscscan.com/address/0x167d4A1658DD960B2945131Cd90ca4fdf0FAa242) |
| **Attack tx** | [`0x7ca804d016be67c570a10a620b9ae3027fd6b03d0965da3ec78912be067af024`](https://bscscan.com/tx/0x7ca804d016be67c570a10a620b9ae3027fd6b03d0965da3ec78912be067af024) |
| **Chain / block / date** | BSC / fork block 50,311,055 / May 2025 |
| **Compiler** | Unknown — source not verified on BscScan |
| **Bug class** | The public selector `0x88417d5c` (`mintTokens(...)`) transfers arbitrary ERC20 tokens held by the contract to `msg.sender` without any `owner()` / storage-owner check, so any caller can drain every token balance the contract custody-holds. |

## TL;DR

The victim contract at `0x000004…D0000` exposes a function with selector `0x88417d5c` whose decoded signature is `mintTokens(uint256,bool,bool,(address,uint256)[])` (the test's `abi.encodeWithSelector(0x88417d5c, uint256(0), uint256(0), uint256(0), entries)` reproduces exactly that shape, and the trace labels the call `Unverified Victim::mintTokens(0, false, false, [(token, amount)])` — [output.txt:1655](output.txt)). Each entry of the trailing array causes the contract to call `token.transfer(msg.sender, amount)`. There is no `onlyOwner` / `onlyStorageOwner` guard on this path.

The PoC proves the precondition is trivially satisfied: it calls `owner()` on the victim and gets `0x2218FE64fCA8143A790EFD5d6192D09Ca3e11A98` ([output.txt:1647-1649](output.txt)), then asserts the attacker (`0x9Aac…902e`) is not the owner, and then — as that same non-owner — drains three tokens in three separate calls. The victim's full USDT balance of `59.878747` ([output.txt:1656](output.txt), `59878747000000000000` wei) and full aBnbETH balance of `2.005496423943642118` ([output.txt:1673](output.txt), `2005496423943642118` wei) are moved to the caller verbatim, and a `Transfer` event for each is emitted from victim→caller ([output.txt:1657](output.txt), [output.txt:1690](output.txt)).

This is a pure, permissionless access-control failure. No flash loan, no price manipulation, no privileged role — the function is a public, unguarded token-sweep. The contract held custody of USDT, aBnbETH and HODL; an arbitrary caller emptied all three in a single transaction, netting the ≈5,658 USD reported and additionally ~1.415e24 units of HODL (a fee-on-transfer style token where a tax redirects ~5% to itself).

## Background — what the victim contract does

The victim contract is deployed at a vanity address (`0x000004A70f92f1b22…D0000`) on BSC and its source is not verified, so its design intent must be inferred from on-chain behaviour. What the trace reveals:

1. **It is an `Ownable`-style contract** — it answers an `owner()` view that returns `0x2218FE64fCA8143A790EFD5d6192D09Ca3e11A98` ([output.txt:1647](output.txt)). So there IS an owner concept in storage; the bug is that it is not enforced on the drain path.
2. **It custody-holds multiple ERC20 tokens.** At the fork block it held `59.878747 USDT` (BSC USDT, `0x55d3…7955`), `2.005496… aBnbETH` (an aToken/interest-bearing BNB-ETH position, `0x2E94…1E2F`, which internally delegates to a `0x6c23…` proxy that reads a `getReserveNormalizedIncome` from a lending pool — [output.txt:1689-1692](output.txt)), and `1.4901522…e24 HODL` (`0x32B4…034C`, a fee-on-transfer token that burns/taxes ~5% on transfer — [output.txt:1720-1721](output.txt)).
3. **It exposes an admin-flavoured function `mintTokens(uint256,bool,bool,(address,uint256)[])` (selector `0x88417d5c`).** The decoded name "mintTokens" and the `(bool,bool)` flags suggest the author intended this as a privileged minting/airdrop/dispatch routine: it takes three scalars plus a list of `{token, amount}` entries and, per entry, moves `amount` of `token` out of the contract. The first three args (`0, false, false` in the PoC) are ignored for the drain; only the entries array matters.

In short: this is a custody/dispatch contract that holds tokens and was meant to distribute them under owner control. The defect is that the distribute path forgot the guard.

## The vulnerable code

> The contract is **UNVERIFIED** on BscScan (per `@Info` in the PoC and the empty `sources/` directory). The function below is **RECONSTRUCTED** from the foundry `-vvvvv` trace. The signature and semantics are grounded in the trace: the call decodes as `mintTokens(uint256,bool,bool,(address,uint256)[])`, and the only external effect of each entry is a `token.transfer(msg.sender, amount)` that succeeds and emits `Transfer(victim, msg.sender, amount)`.

```solidity
// RECONSTRUCTED from output.txt — selector 0x88417d5c.
// Trace label:  Unverified Victim::mintTokens(uint256 _arg0, bool _arg1, bool _arg2, TokenAmount[] entries)
// Trace effect: for each {token, amount} in entries -> IERC20(token).transfer(msg.sender, amount)

struct TokenAmount {
    address token;
    uint256 amount;
}

function mintTokens(
    uint256,                     // arg0 — unused by the drain
    bool,                        // arg1 — unused by the drain
    bool,                        // arg2 — unused by the drain
    TokenAmount[] calldata entries
) external /* ❌ NO onlyOwner / onlyStorageOwner / access check */ {
    for (uint256 i = 0; i < entries.length; i++) {
        // The trace shows a direct transfer of the victim's full balance to msg.sender:
        //   USDT:   Transfer(victim, caller, 59878747000000000000)   [output.txt:1657]
        //   aBnbETH: Transfer(victim, caller, 2005496423943642118)   [output.txt:1690]
        //   HODL:   Transfer(victim, caller, 1415644663750037670000000)  [output.txt:1721]
        IERC20(entries[i].token).transfer(msg.sender, entries[i].amount);
    }
}
```

### Why the reconstruction is faithful

- The PoC packs the call as `abi.encodeWithSelector(0x88417d5c, uint256(0), uint256(0), uint256(0), entries)` where `entries` is `TokenAmount[]` = `(address,uint256)[]`. Foundry decodes that to `mintTokens(0, false, false, [(token, amount)])` ([output.txt:1655](output.txt), [1673](output.txt), [1717](output.txt)).
- Inside each `mintTokens` call the **only** outbound call to the entry's token is a `transfer(Arbitrary Caller, amount)` whose `amount` equals the victim's current balance of that token ([output.txt:1656](output.txt) USDT, [1673](output.txt) aBnbETH, [1717](output.txt) HODL). The contract does not mint anything — the name is misleading; it only transfers out.
- The function executes to `[Stop]` with no revert and no internal `require(owner == msg.sender)`-style failure even though `msg.sender` (`0x9Aac…902e`) is provably not `owner()` (`0x2218…A98`) — [output.txt:1647-1651](output.txt). That is the missing-check signature.

## Root cause — why it was possible

1. **No access-control modifier on `mintTokens` (selector `0x88417d5c`).** The contract stores an `owner` (it answers `owner()` correctly) but the drain entrypoint never reads it. The trace shows a non-owner address (`0x9Aac…902e`) completing the call without revert ([output.txt:1655](output.txt)).
2. **`msg.sender` is used as the transfer destination.** Even if the function were meant to dispatch to a fixed recipient or to the owner, it instead sends the tokens to whoever called. Combined with cause #1 this turns the function into a public sweep.
3. **The amount per entry is attacker-controlled and uncapped.** The PoC passes the victim's *entire* balance of each token as `amount`, and the contract honours it without clamping to an allowance, a per-token cap, or an accounting debit. Nothing stops `amount = balanceOf(this)`.
4. **Misleading function name hides intent.** "mintTokens" reads as a mint routine, which likely caused the author/reviewer to mentally file it under "trusted operation" and skip the guard. The actual behaviour is a transfer-out, not a mint.

## Preconditions

- **Permissionless.** No privileged role, no flash loan, no special state required. Any EOA or contract can call `0x88417d5c` on the victim.
- The victim must custody-hold any ERC20 the attacker wants. At block 50,311,055 that included USDT, aBnbETH, and HODL — all drained in the reproduction.
- The attacker does not need to be the `owner()`. The PoC explicitly asserts `arbitraryCaller != victim.owner()` before draining ([output.txt:1647-1651](output.txt)).

## Attack walkthrough (with on-chain numbers from the trace)

The PoC (`testExploit`, [output.txt:1591](output.txt)) performs three identical drains, one per token. Each drain reads the victim's current balance, packs it as a single-entry `TokenAmount[]`, and calls `mintTokens` from the non-owner `arbitraryCaller`.

| # | Call (from `arbitraryCaller`, non-owner) | Victim balance read | Transferred to attacker | Trace ref |
|---|---|---|---|---|
| 0 | `owner()` sanity check | returns `0x2218…A98` (≠ attacker) | — | [output.txt:1647](output.txt) |
| 1 | `mintTokens(0,false,false,[(USDT, 59.878747e18)])` | `59.878747` USDT | `59.878747` USDT (full) | [output.txt:1655-1657](output.txt) |
| 2 | `mintTokens(0,false,false,[(aBnbETH, 2.005496423943642118e18)])` | `2.005496423943642118` aBnbETH | `2.005496423943642118` aBnbETH (full) | [output.txt:1673-1690](output.txt) |
| 3 | `mintTokens(0,false,false,[(HODL, 1.4901522776316186e24)])` | `1.4901522776316186e24` HODL | `1.41564466375003767e24` HODL (~95%, rest taxed to HODL itself) | [output.txt:1717-1721](output.txt) |

**Accounting (per the test's own assertions, all PASS):**
- Victim post-drain balances: USDT = 0, aBnbETH = 0, HODL = 0 (all fully drained) — [output.txt](output.txt) final `assertEq(..., 0)` blocks.
- Attacker gain: `+59.878747 USDT`, `+2.005496423943642118 aBnbETH`, `+1.41564466375003767e24 HODL` (≥90% of the victim's HODL holding) — [output.txt:1778](output.txt), [1795](output.txt), and the `assertGt` at the HODL check.
- Reported realised loss: **5,658.46 USD** (`@KeyInfo`), consistent with the USDT + aBnbETH leg at contemporaneous prices; the HODL leg is an illiquid bonus.

The "Before/After" harness echoes the attacker's tracked funding tokens (USDT, aBnbETH) only:

```
=== Before exploit ===
 USDT Balance: 0.000000000000000000        [output.txt:1601]
 aBnbETH Balance: 0.000000000000000000     [output.txt:1618]
=== After exploit ===
 USDT Balance: 59.878747000000000000       [output.txt:1778]
 aBnbETH Balance: 2.005496423943642118     [output.txt:1795]
```

## Diagrams

```mermaid
sequenceDiagram
    participant Attacker as Arbitrary Caller 0x9Aac..902e
    participant Victim as Victim 0x000004..D0000
    participant Token as ERC20 token (USDT/aBnbETH/HODL)

    Note over Attacker,Victim: No owner check on selector 0x88417d5c
    Attacker->>Victim: owner()
    Victim-->>Attacker: 0x2218..A98 (not the attacker)
    Note over Attacker: confirmed NOT owner, proceeds anyway

    loop for each token in victim's balances
        Attacker->>Victim: mintTokens(0,false,false, [(token, balanceOf(victim))])
        Note over Victim: no onlyOwner guard; msg.sender = caller
        Victim->>Token: transfer(msg.sender, amount)
        Token-->>Victim: true
        Token-->>Attacker: Transfer(victim, attacker, amount)
    end

    Note over Attacker: holds all of victim's USDT + aBnbETH + ~95% HODL
```

```mermaid
flowchart TD
    A["Call selector 0x88417d5c<br/>mintTokens(uint,bool,bool,(addr,uint)[])"] --> B{"owner()/storage-owner<br/>check?"}
    B -- "❌ MISSING" --> C["Loop over entries"]
    B -- "should be: require(msg.sender == owner)" -.-> X["revert"]
    C --> D["IERC20(token).transfer(msg.sender, amount)"]
    D --> E["amount = attacker-supplied,<br/>uncapped, == victim balance"]
    E --> F["Victim swept clean"]
```

## Remediation

1. **Gate the function behind the owner check the contract already stores.** Add an `onlyOwner` (or equivalent `onlyStorageOwner`) modifier to `mintTokens` / selector `0x88417d5c`:
   ```solidity
   function mintTokens(uint256, bool, bool, TokenAmount[] calldata entries) external onlyOwner { ... }
   ```
2. **Do not send to `msg.sender`.** If the intent is to dispatch to a stored recipient or to the owner, transfer to that fixed address — never to the caller of an admin routine.
3. **Cap `amount` against an internal accounting ledger** rather than trusting the caller-supplied value, so even a future owner compromise or a logic bug cannot move more than the protocol intends per call.
4. **Re-audit every other selector on the contract** for the same missing-modifier pattern. An unverified contract with one unguarded admin-flavoured entrypoint likely has more; treat this as a signal to verify source and run a full access-control review.
5. **Verify the contract source on BscScan** and, for the future, enforce verification + a pre-deploy Slither/custom `onlyOwner` lint on any custody contract.

## How to reproduce

The PoC runs **fully offline** via the shared anvil harness from the committed `anvil_state.json` — no RPC needed. From the registry root:

```bash
_shared/run_poc.sh 2025-05-unverified_0000_exp -vvvvv
```

- **Fork:** BSC (chain id 56), fork block **50,311,055** (loaded from `anvil_state.json`).
- **Expected tail:** `[PASS] testExploit()` followed by `1 tests passed, 0 failed, 0 skipped` ([output.txt:1562](output.txt), end-of-file suite summary).
- **Balance proof in the log:**
  - Before: `USDT Balance: 0.000000000000000000`, `aBnbETH Balance: 0.000000000000000000` ([output.txt:1601](output.txt), [1618](output.txt))
  - After: `USDT Balance: 59.878747000000000000`, `aBnbETH Balance: 2.005496423943642118` ([output.txt:1778](output.txt), [1795](output.txt))

The reproduction also demonstrates the missing-owner precondition explicitly: the test calls `victim.owner()`, asserts the caller is not that owner, and then drains anyway — all assertions PASS, mechanically confirming the access-control defect.

*Reference: [https://t.me/defimon_alerts/1184](https://t.me/defimon_alerts/1184) (alert cited in `@Analysis` of the PoC).*
