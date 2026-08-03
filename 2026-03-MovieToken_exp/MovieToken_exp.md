# Movie Token (MT) double-count burn — BSC Mar 2026 ~$242K

<!-- non-defihacklabs -->

## Summary

| Field | Value |
|-------|--------|
| **Date** | 2026-03-10 |
| **Chain** | BSC |
| **Loss** | ~$242K (~381.7 WBNB) |
| **Bug class** | Sell path double-counts into `pendingBurnAmount`; public burn drains pair inventory |
| **Token** | `0xb32979f3A5b426a4A6Ae920f2B391D885Abf4C18` (Movie Token / MT) |
| **Pair** | `0x037E6EB26275DBfE3A5244239BBe973f1A56b449` (MT/WBNB) |
| **LP Mining** | `0x139bd2ECFDE76f5311D7beeb2E05cba6feDE26D6` |
| **Attack tx** | `0xfb57c980286ea8755a7b69de5a74483c44b1f74af4ab34b7c52e733fc62dfca6` @ block **85677691** |

## Root cause

1. On sells, `MT._transfer` delivers net tokens to the pair for the swap **and** adds the same net amount to `pendingBurnAmount` (`PendingBurnRecorded`).
2. Anyone can call `LP_MINING.distributeDailyRewards()` → `MT.extractFromPoolForLpMining` → executes pending burn from the **pair’s** MT balance + `pair.sync()`.
3. Pair MT reserves collapse while WBNB stays → price inflates → attacker dumps remaining MT for nearly all pair WBNB.

## Buy restriction + bypass (required for PoC)

Open buys to arbitrary addresses revert: *“Buying not allowed: tokens can only be obtained through LP mining”*.

Live attacker bypass (reproduced in PoC):

1. Tiny direct `pair.swap` buy to self + seed tiny LP.
2. Large `swapExactTokensForTokensSupportingFeeOnTransferTokens` with **`to = PancakeRouter`** (router is allowed).
3. `removeLiquidityETHSupportingFeeOnTransferTokens` flushes the router’s entire MT balance to the attacker.

Then: pair flash-swap of WBNB repaid with MT (records huge pending burn) → second buy/flush → `distributeDailyRewards` → dump.

## Addresses

| Role | Address |
|------|---------|
| Attacker EOA | `0xDB0901A3254f47c0CE57fFFCE2C730Bc33A1c0e1` |
| Attack contract | `0xDf7eD22d1FA65eAc11A0806b7bb5F35d4A1e957D` |
| Flash (Moolah) | `0x8F73b65B4caAf64FBA2aF91cC5D4a2A1318E5D8C` |
| Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

## PoC

| Field | Value |
|-------|--------|
| Folder | `2026-03-MovieToken_exp` |
| Test | `test/MovieToken_exp.sol` |
| Fork | BSC block **85677690** |
| RPC | `https://bsc-mainnet.public.blastapi.io` |
| Offline anvil_state | not shipped (ONLINE archive) |

### Run

```bash
unset ETH_RPC_URL FOUNDRY_ETH_RPC_URL
cd 2026-03-MovieToken_exp
forge test --match-contract MovieToken_exp -vv --gas-limit 100000000
```

### Expected

- `Profit WBNB wei: ~381746808261289395927` (~**381.75 WBNB**, matches live ~381.7)

## References

- CertiK: https://www.certik.com/blog/movie-token-incident-analysis
- Defimon: https://x.com/DefimonAlerts/status/2031324036181954842
