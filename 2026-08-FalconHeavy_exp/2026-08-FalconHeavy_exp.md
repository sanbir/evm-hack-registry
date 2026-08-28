# Falcon Heavy (FH) — Sell Path Burns FH From the Pancake Pair

<!-- non-defihacklabs: Crypto Training original detection & analysis (Twitter hack alerting) -->

> **Vulnerability classes:** vuln/defi/fee-manipulation · vuln/logic/incorrect-state-transition · vuln/defi/pair-reserve-desync

> **Reproduction:** the PoC compiles & runs in an isolated Foundry project at
> [this project folder](.). Full verbose trace: [output.txt](output.txt).
> Verified vulnerable source: [FHToken.sol](sources/FHToken_dCf0DF/contracts_FHToken.sol).

---

## Key info

| | |
|---|---|
| **Loss** | **~19,999 USDT (~$20K)** — exact PoC match `19999018106552928530404` wei (~19,999.018 USDT) |
| **Vulnerable contract** | `FHToken` — [`0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37`](https://bscscan.com/address/0xdcf0dfe0053677a67610c6d08ea1f5c78df8ca37#code) |
| **Victim pool** | PancakeV2 FH/USDT — [`0x8f2d1A3992856a860304f1B86534B6B129Cc4df7`](https://bscscan.com/address/0x8f2d1a3992856a860304f1b86534b6b129cc4df7) |
| **Flash-loan source** | Moolah (ERC1967 proxy) — [`0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C`](https://bscscan.com/address/0x8f73b65b4caaf64fba2af91cc5d4a2a1318e5d8c) → impl [`0x9321587e…bb79a`](https://bscscan.com/address/0x9321587ea0dc8247f8f03e8696c047b2713bb79a) |
| **Attacker EOA** | [`0x7FA3bC0d5667fFd14d7ACD6Ce5f2432AC13a6FDA`](https://bscscan.com/address/0x7fa3bc0d5667ffd14d7acd6ce5f2432ac13a6fda) |
| **Attack contract** | [`0x727Fb666E3F2531e807E987532C6e2C22ADC45aD`](https://bscscan.com/address/0x727fb666e3f2531e807e987532c6e2c22adc45ad) (unverified) |
| **Attack tx** | [`0x7a3cadc2f33e000b0091307df62db2f5cc79ab8e0b022fd84de9e1c2c0745bd2`](https://bscscan.com/tx/0x7a3cadc2f33e000b0091307df62db2f5cc79ab8e0b022fd84de9e1c2c0745bd2) |
| **Chain / block / date** | BSC / fork **117,979,401** (attack mined in **117,979,402**) / 2026-08-26 |
| **Bug class** | Deflationary sell tax burns **80% of netAmount from the Pancake pair** (and sends 20% from the pair to treasury), then `sync()`s — desyncing LP reserves so a flash-loan buy–sell loop drains USDT |

---

## TL;DR

1. FH is a fee-on-transfer / “deflationary” BSC token paired with USDT on PancakeSwap V2.

2. On a **sell** (`to == pair`), after taking a dynamic sell fee from the seller, the token burns **80% of `netAmount` from the pair’s balance** and transfers **20% from the pair to the treasury**, then calls `pair.sync()`.

3. Those pair-side burns are **not** the seller’s tokens — they deplete LP inventory and lock a lower FH reserve via `sync()` *before* the seller’s net FH is credited.

4. An unprivileged attacker flash-borrows ~26k USDT from Moolah, runs **25 buy–burn–sell cycles** against the FH/USDT pair, repays the flash loan, and walks away with **~19,999 USDT**. Pair USDT falls from ~19,999.5 → ~0.48.

5. This is a classic **pair-burn / reserve-desync** token bug — not OpSec, not a router double-transfer (contrast NEX/AIC FoT skim).

---

## Background

`FHToken` (`0xdCf0…cA37`, symbol **FH**) creates its USDT pair in the constructor and marks it `isPair`. Buys require a buyer whitelist (aggregators / routers are pre-whitelisted). Sells charge a dynamic fee to `SLIPPAGE_WALLET`, then apply a “deflation” rule meant to burn toward a target supply of 2.1M FH.

The deflation rule is where the accounting breaks: it burns and taxes **`pair`**, not the seller.

---

## The vulnerable code

```solidity
// sources/FHToken_dCf0DF/contracts_FHToken.sol (sell branch)
} else if (isSell) {
    feeAmount = (amount * sellFee) / FEE_DENOMINATOR;
    uint256 netAmount = amount - feeAmount;

    if (!inSwap) {
        inSwap = true;

        if (feeAmount > 0) {
            super._transfer(sender, SLIPPAGE_WALLET, feeAmount);
        }

        // 卖出净额：80% 销毁，20% 进国库
        if (netAmount > 0 && totalSupply() > targetSupply) {
            uint256 burnAmount = (netAmount * 80) / 100;
            uint256 treasuryAmount = netAmount - burnAmount;

            if (burnAmount > 0) {
                _burn(pair, burnAmount);                      // @> VULN: burns LP FH
                totalBurned += burnAmount;
                emit TokensBurned(sender, burnAmount);
            }

            if (treasuryAmount > 0) {
                super._transfer(pair, TREASURY_WALLET, treasuryAmount); // @> also from pair
            }
            try IUniswapV2Pair(pair).sync() {} catch {}       // locks depleted FH reserve
        }

        super._transfer(sender, recipient, netAmount);       // seller FH credited AFTER sync
        inSwap = false;
    }
}
```

**Bug:** on every sell, `netAmount` worth of FH is removed from the **pair** (80% burn + 20% treasury) and `sync()` freezes that lower FH reserve **before** the seller’s `netAmount` is transferred in. The subsequent `pair.swap` therefore sells against an artificially thin FH reserve and extracts excess USDT.

---

## Attack flow (one tx)

1. **Flash-loan** `25,999.35` USDT from Moolah (`flashLoan` → `onMoolahFlashLoan`).
2. For each of **25** iterations (sizes taken from the live tx):
   - Push USDT into the FH/USDT pair and `swap` FH out to the buyer-whitelisted Pancake V3 router, then `sweepToken` to the exploit contract.
   - `transfer` FH to the pair (triggers the sell burn-from-pair + `sync`).
   - `pair.swap` USDT out against the depleted FH reserve.
3. **Approve / repay** the Moolah flash loan; leftover **~19,999.018 USDT** goes to the attacker EOA.

---

## PoC

```text
cd 2026-08-FalconHeavy_exp
forge test --match-test testExploit -vvv
```

Offline (committed state):

```text
_shared/run_poc.sh 2026-08-FalconHeavy_exp -vvvvv
```

Expected:

```text
[PASS] testExploit()
Pair USDT drained: 19999.018106552928530404
Attacker USDT profit: 19999.018106552928530404
```

---

## References

- Alert: https://x.com/TenArmorAlert/status/2092427353456812207
- Attack tx: https://bscscan.com/tx/0x7a3cadc2f33e000b0091307df62db2f5cc79ab8e0b022fd84de9e1c2c0745bd2
- FH token: https://bscscan.com/address/0xdCf0DFe0053677A67610c6d08EA1f5c78DF8cA37#code
- Pair: https://dexscreener.com/bsc/0x8f2d1a3992856a860304f1b86534b6b129cc4df7
