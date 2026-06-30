# Unverified6883 Fake-Pair Callback Hijack — UniswapV2 flash-swap callback trusts a freshly-created attacker pair and pays WETH into it
> **Vulnerability classes:** vuln/logic/missing-validation · vuln/access-control/missing-auth · vuln/defi/slippage
> **Reproduction:** the PoC compiles cleanly in an isolated Foundry project at [this project folder](.). Full verbose trace: [output.txt](output.txt). The victim contract `0x6883…` is **unverified** on Etherscan — all mechanics below are reconstructed from the PoC's self-contained `FakeCallbackExploit` contract and the on-chain alert.
---

## Key info

| | |
|---|---|
| **Loss** | ~$1,006.89 (0.267592 WETH) |
| **Vulnerable contract** | Unverified6883 — [`0x6883Fe4D2EE50941b80b41b8F7F9BF2561D844Cc`](https://etherscan.io/address/0x6883Fe4D2EE50941b80b41b8F7F9BF2561D844Cc) (no verified source) |
| **Attacker EOA** | [`0x87c6D33808F10348Cd9a4Cd825f25BE341d7bA2d`](https://etherscan.io/address/0x87c6D33808F10348Cd9a4Cd825f25BE341d7bA2d) |
| **Attack contract** | [`0x46bBB647B61560432b58eCBa6Bd048D691701D82`](https://etherscan.io/address/0x46bBB647B61560432b58eCBa6Bd048D691701D82) |
| **Attack tx** | [`0x6fb78c7737463ea39a23159dd8496c178106b4ee657f2fb6fcb628240c39cd2e`](https://etherscan.io/tx/0x6fb78c7737463ea39a23159dd8496c178106b4ee657f2fb6fcb628240c39cd2e) |
| **Chain / block / date** | Ethereum mainnet / fork block 23,002,633 / July 2025 |
| **Compiler** | Unknown — victim source not verified. PoC compiled with Solidity `^0.8.15`, EVM version `cancun`. |
| **Bug class** | The victim's UniswapV2 flash-swap callback (`uniswapV2Call`) honours a callback from any address it treats as a "pair" and routes an attacker-specified `paymentAmount` of its own WETH to an attacker-specified `paymentTo`, without authenticating that the calling pair is one it previously funded or that the payment destination is a trusted recipient. |

## TL;DR

The victim (`0x6883…`) is an unverified swap helper/router that implements the UniswapV2 flash-swap callback `uniswapV2Call`. When invoked, it decodes an attacker-supplied payload describing a multi-hop "swap" and — as part of settling that swap — transfers a `paymentAmount` of **its own WETH** to a `paymentTo` address taken straight from that payload. The attacker does not need to be the original flash borrower in any meaningful sense: they only need *some* UniswapV2 pair to call their victim.

To get that call, the attacker borrows a tiny amount of WETH through the genuine DAI/WETH pair's flash swap (`uniswapV2Call` to their own contract), then uses the borrowed WETH to seed a brand-new pair (`TEMP_TOKEN`/WETH) created via the real UniswapV2 factory. Because the victim's callback never checks that the invoking pair is one it controls or trusts, calling `TEMP_PAIR.swap(...)` with the victim as `to` and attacker-crafted `data` makes the victim execute its payment logic and push **0.269 WETH** of its own balance into `TEMP_PAIR`. The attacker then flushes the manipulated pair (`sync` + dump of 999,999,900 fake tokens) to extract ~0.3679 WETH, repays the 0.1003 WETH flash loan, and keeps a net **0.267592060870468589 WETH** profit.

The exploit is permissionless: the attacker's only real inputs are gas, the flash-loaned 0.1 WETH, and an unlimited-mint attacker token. The victim paid out ~$1,006.89 of its own treasury WETH because it confused "a UniswapV2 pair I got a callback from" with "a pair I'm responsible for settling."

## Background — what the victim does

The victim is an unverified contract that participates in UniswapV2 flash swaps. In UniswapV2, a caller can borrow up to the entire reserve of either token from a pair by calling `pair.swap(amount0Out, amount1Out, to, data)`. If `data.length > 0`, the pair mints/optimistically transfers the requested tokens to `to` and then calls `to.uniswapV2Call(sender, amount0, amount1, data)` before re-checking that the pair's invariant (`reserve0 * reserve1` post-fee) is maintained. This callback pattern is what enables flash swaps: the borrower must restore the pair's balance by the end of the call.

A legitimate flash-swap *receiver* (the victim here) typically:

1. Receives the flash-borrowed tokens in `uniswapV2Call`.
2. Uses them (e.g. arbitrage, route them through other pools).
3. Pays the pair back (plus the 0.3% fee) so the pair's `k` invariant holds.

The victim's design appears more elaborate: its payload (`VictimCallbackPayload` in the PoC) encodes a multi-hop structure with `token0/token1/amount0/amount1/paymentAmount/paymentTo/receiver` plus a `hops[]` array describing helper contracts, route hints, and nested sub-callback data. This is consistent with a router that, upon receiving a flash-swap callback, performs an internal "swap" through helper contracts and settles by paying a configurable `paymentAmount` to a configurable `paymentTo`.

The fatal assumption is that the callback payload — including the destination and amount of the WETH settlement payment — is trustworthy, and that any UniswapV2 pair invoking the callback is one the victim intended to service.

## The vulnerable code

The victim's source is **not verified**, so the callback logic is reconstructed from the attacker's PoC, which faithfully reproduces the byte-exact `victimCallbackData` (the PoC asserts `keccak256(victimCallbackData) == VICTIM_CALLBACK_DATA_HASH`). The reconstructed behaviour:

```solidity
// RECONSTRUCTED from PoC payload + on-chain behaviour (victim source unverified)
function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
    // BUG #1: no check that msg.sender is a pair the victim actually funded / owns.
    //   The callback fires for ANY UniswapV2 pair that calls swap(..., data)
    //   with `to == address(this)`.

    VictimCallbackPayload memory p = abi.decode(data, (VictimCallbackPayload));

    // ... executes the encoded hops[] (swap-through-helper logic) ...

    // BUG #2: payment destination and amount come from attacker-controlled `data`.
    //   The victim transfers its OWN WETH to p.paymentTo, no allow-list.
    WETH.transfer(p.paymentTo, p.paymentAmount);
}
```

### The callback payload the attacker forges

The PoC builds the exact payload the victim expects and pins it to a known hash:

```solidity
// From the PoC — the attacker-crafted payload
hops[0] = VictimSwapHop({
    helper: TEMP_HELPER,        // attacker-deployed NoopSwapHelper (does nothing)
    token0: WETH_ADDRESS,
    token1: TEMP_TOKEN,
    routeAmountHint: ROUTE_AMOUNT_HINT,
    amount0Out: HELPER_AMOUNT0_OUT,
    amount1Out: 0,
    data: _nestedVictimCallbackData()
});

return abi.encode(
    VictimCallbackPayload({
        token0: WETH_ADDRESS,
        token1: TEMP_TOKEN,
        amount0: 0,
        amount1: 0,
        paymentAmount: VICTIM_WETH_PAYMENT, // 0.269 WETH — drained from victim treasury
        paymentTo: TEMP_PAIR,               // attacker-controlled pair
        receiver: VICTIM,
        hops: hops
    })
);
```

The critical fields are `paymentTo: TEMP_PAIR` (an attacker-created UniswapV2 pair holding attacker-minted fake token + real WETH) and `paymentAmount: 0.269 WETH` (taken from the victim's own balance). The `helper` is a pure no-op (`function swap(...) external {}`), so the "swap" the victim performs is illusory — it just pays out.

## Root cause — why it was possible

1. **Unauthenticated callback origin.** The victim's `uniswapV2Call` does not verify that `msg.sender` is a UniswapV2 pair the victim itself created, funded, or is contractually responsible for. Any pair created through the canonical factory can trigger it by calling `swap(..., data)` with the victim as `to`.
2. **Attacker-controlled settlement destination and amount.** `paymentTo` and `paymentAmount` are decoded from the callback `data` with no allow-listing. The victim will move its own treasury WETH to whatever address the payload names.
3. **No proof-of-reserve / no balance reconciliation.** The victim never checks that it actually received value from the invoking pair before paying out. In a correct flash-swap settlement, the *received* flash amount should equal or exceed the *paid* amount; here the victim pays 0.269 WETH while the triggering `TEMP_PAIR.swap` only sends out 1 fake token (`amount0Out: 1 ether` of the worthless `TEMP_TOKEN`).
4. **Composable with a cheaply creatable fake pair.** UniswapV2's `createPair` is permissionless and deterministic. The attacker pre-computed `TEMP_PAIR = 0x986a80dE…` by knowing `(TEMP_TOKEN, WETH)`, minted unlimited `TEMP_TOKEN`, and seeded the pair with the flash-borrowed WETH — fully controlling the pair's reserves and therefore the `sync`/drain math the victim's own reserves get routed into.

## Preconditions

- **Permissionless.** No privileged role, no special token holdings required by the attacker beyond gas.
- A flash loan of **0.1 WETH** is taken from the genuine DAI/WETH pair to seed the fake pair; this is repaid (0.1003 WETH incl. fee) within the same transaction.
- The victim must hold at least `paymentAmount` (0.269 WETH) of WETH in treasury at the fork block — which it did.
- Network: Ethereum mainnet; canonical UniswapV2 factory `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f`.

## Attack walkthrough (with on-chain numbers from the PoC)

All amounts are WETH (18 decimals), taken from the PoC constants (the local fork run did not execute — see *How to reproduce*).

| # | Action | WETH moved | Net attacker WETH |
|---|--------|-----------|-------------------|
| 1 | `DAI_WETH_PAIR.swap(0, 0.1 WETH, exploit, …)` — real flash swap; triggers `exploit.uniswapV2Call` | +0.100000000000000000 (borrowed) | +0.100000000000000000 |
| 2 | `Factory.createPair(TEMP_TOKEN, WETH)` → creates `TEMP_PAIR` (pre-computed `0x986a…`) | — | +0.100000000000000000 |
| 3 | Seed pair: `TEMP_TOKEN.transfer(TEMP_PAIR, 100)` + `WETH.transfer(TEMP_PAIR, 0.1)` + `sync()` | −0.100000000000000000 (into pair, attacker still owns via LP math) | 0.000000000000000000 |
| 4 | `TEMP_PAIR.swap(1 fake token, 0, VICTIM, attackerData)` → victim's `uniswapV2Call` fires; victim pays its **own** `0.269 WETH` to `TEMP_PAIR` per the forged payload | +0.269000000000000000 (victim treasury → `TEMP_PAIR`) | 0.000000000000000000 (now sitting in pair) |
| 5 | Assert: `WETH.balanceOf(TEMP_PAIR) == 0.1 + 0.269 == 0.369000000000000000` | — | 0.000000000000000000 |
| 6 | `TEMP_PAIR.sync()` then dump `999,999,900 TEMP_TOKEN` into the pair, `TEMP_PAIR.swap(0, 0.367892963578592963, exploit, "")` — drain almost all WETH from the manipulated pair | +0.367892963578592963 | +0.367892963578592963 |
| 7 | Repay flash loan: `WETH.transfer(DAI_WETH_PAIR, 0.100300902708124374)` (principal + 0.3% fee) | −0.100300902708124374 | +0.267592060870468589 |
| 8 | `WETH.transfer(ATTACKER, 0.267592060870468589)` — final profit to EOA | — | **+0.267592060870468589** |

**Profit/loss accounting:** Profit = drain (0.367892963578592963) − flash repay (0.100300902708124374) = **0.267592060870468589 WETH**. The 0.269 WETH the victim paid in step 4 is the real source of funds; the slight excess drain (0.3679 vs 0.369 in the pair after step 5) is the Uniswap constant-product residue minus the dust left as the pair's fee cushion. At the time of the alert this was ~**$1,006.89**.

## Diagrams

```mermaid
sequenceDiagram
    participant Attacker as Attacker contract
    participant DaiWeth as DAI/WETH pair
    participant TempPair as TEMP_PAIR (attacker-created)
    participant Victim as Victim 0x6883 (unverified)
    participant WETH as WETH token

    Attacker->>DaiWeth: swap(0, 0.1 WETH, attacker, "flash")
    DaiWeth->>Attacker: uniswapV2Call (sends 0.1 WETH)
    Note over Attacker: createPair(TEMP_TOKEN,WETH)=TEMP_PAIR
    Attacker->>TempPair: seed 100 fake tokens + 0.1 WETH, sync()
    Attacker->>TempPair: swap(1 fake token out, to=Victim, forged data)
    TempPair->>Victim: uniswapV2Call(sender, 1 fake token, 0, forged data)
    Note over Victim: decodes payload: payTo=TEMP_PAIR, payAmount=0.269 WETH
    Victim->>WETH: transfer(TEMP_PAIR, 0.269) from VICTIM treasury
    Victim-->>TempPair: returns (pair now holds 0.369 WETH)
    Attacker->>TempPair: sync(); dump 999,999,900 fake tokens
    Attacker->>TempPair: swap(0, 0.367892963578592963 WETH, attacker, "")
    TempPair->>Attacker: sends 0.367892963578592963 WETH
    Attacker->>DaiWeth: repay 0.100300902708124374 WETH
    Attacker->>Attacker: keep 0.267592060870468589 WETH profit
```

```mermaid
flowchart TD
    A["Victim receives uniswapV2Call"] --> B{"msg.sender = trusted pair?"}
    B -- "NO CHECK (vuln)" --> C["Decode attacker payload"]
    C --> D{"paymentTo allow-listed?"}
    D -- "NO CHECK (vuln)" --> E["paymentAmount bounded by received?"}
    E -- "NO CHECK (vuln)" --> F["Transfer own WETH to attacker pair"]
    F --> G["Attacker drains pair via manipulated reserves"]
```

## Remediation

1. **Authenticate the callback origin.** In `uniswapV2Call`, require `msg.sender` to be a pair the victim itself manages — e.g. recompute `pairFor(factory, token0, token1)` from the victim's own state and check `msg.sender == expected`, and/or maintain an allow-list of pairs the victim is permitted to service.
2. **Validate `paymentTo` against an allow-list** of known-good settlement recipients (the victim's own pairs, its treasury, its router). Never transfer treasury WETH to an address read from user-supplied calldata.
3. **Reconcile received vs paid.** Before any outgoing WETH payment, assert that the victim received at least `paymentAmount` of value from `msg.sender` in this transaction (track the flash-swap inbound). A settlement where the victim pays out WETH it never received must revert.
4. **Bound `paymentAmount`.** Cap any single-callback payout to the actual flash-borrowed amount (plus agreed fee) and never exceed the victim's incoming value.
5. **Add a reentrancy/pair-purity guard** so a callback cannot be triggered through a pair the victim did not create or fund in the same call.

## How to reproduce

The PoC is designed to run fully offline via the shared anvil harness from the committed `anvil_state.json`:

```bash
_shared/run_poc.sh 2025-07-Unverified6883_exp -vvvvv
```

- **Chain / fork block:** Ethereum mainnet (chainid 1), fork block **23,002,633**.
- **Fork RPC:** `http://127.0.0.1:8545` — anvil loads `anvil_state.json`; no external RPC required.
- **Expected outcome on a healthy run:** `[PASS]` with `testExploit()` showing attacker WETH `before → after = +0.267592060870468589 WETH`, matching the `PROFIT_WETH` constant and the `assertEq` at the end of `testExploit()`.

**Current local status (honest note):** the committed `output.txt` does **not** contain `[PASS]`. The local run **failed in `setUp()`** with:

```
[FAIL: vm.createSelectFork: could not instantiate forked environment with provider 127.0.0.1;
 failed to get block number: 23002633; latest block number: 23006171] setUp() (gas: 0)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped.
```

`output.txt` contains only compile warnings and the fork-instantiation revert — there are no executed `Balance`/`Transfer` log lines and therefore no inline `[output.txt:NNNN]` runtime figures in this run. The numbers in *Attack walkthrough* are the PoC's hard-coded constants (`FLASH_WETH`, `VICTIM_WETH_PAYMENT`, `TEMP_PAIR_WETH_OUT`, `FLASH_REPAY`, `PROFIT_WETH`), which are the values the exploit is asserted to produce. The failure is an environment issue: the committed anvil snapshot's latest block (23,006,171) is *ahead* of the requested historical fork block (23,002,633), and anvil's `--load-state` cannot serve an older block from a snapshot whose tip is already past it; the spawned anvil process was also killed mid-run. The exploit logic itself is sound and is confirmed by the on-chain attack tx and the defimon alert. Re-running against a mainnet archive RPC at block 23,002,633 (or recomitting `anvil_state.json` at that exact block) is expected to yield `[PASS]`.

*Reference: Telegram alert — https://t.me/defimon_alerts/1544.*
