# GemPadLock reentrancy (Dec 2024) — multi-chain ~$2M

<!-- non-defihacklabs -->

## Summary

| Field | Value |
|-------|--------|
| **Date** | 2024-12-17 |
| **Chains** | Ethereum, BSC, Base (same lock proxy family) |
| **Loss** | ~$1.9–2.2M locked LP / ERC20 inventory |
| **Bug class** | Missing `nonReentrant` + balance-delta fee collect + re-enter `multipleLock` via malicious ERC20 |
| **Proxy** | `0x10B5F02956d242aB770605D59B7D27E51E45774C` |
| **Pre-fix impl** | `0xc25c516eb7d86b5ec38c07182f4a2f73ac81eead` |
| **Post-fix** | `nonReentrant` on public lock/fee paths (impl upgraded) |

## Root cause

1. `collectFees(lockId)` snapshots GemPad balances, calls `INonfungiblePositionManager.collect()` on a UniV3 NFT lock, then refunds balance deltas to the lock owner.
2. `collect()` eventually `transfer`s pool tokens. If the fee token is **attacker-controlled**, `transfer` re-enters `multipleLock`.
3. `multipleLock` pulls attacker tokens into GemPad and registers a **new lockId** while still inside the fee-collect balance window.
4. The balance delta after re-entry is refunded to the attacker; the free lockId later `unlock`s victim inventory (this PoC: FOMO–WETH UniV2 LP).

Call chain:

```text
GemPadLock.collectFees
  → NPM.collect → UniV3Pool.collect
    → MaliciousToken.transfer
      → GemPadLock.multipleLock  // free lock over victim ERC20/LP
```

## Addresses (Ethereum PoC path)

| Role | Address |
|------|---------|
| Attacker EOA | `0xFDd9b0A7e7e16b5Fd48a3D1e242aF362bC81bCaa` |
| Attack contract (historical) | `0x8e18Fb32061600A82225CAbD7fecF5b1be477c43` |
| GemPadLock proxy | `0x10B5F02956d242aB770605D59B7D27E51E45774C` |
| Victim LP example | FOMO `0x9028C2A7f8C8530450549915c5338841Db2a5fEa` / WETH UniV2 pair |
| BSC attack tx | `0x5c21611ae260cf795c304cf9fcf777450acf29916d162964b7ec61c37632a07e` |
| ETH attack tx | `0x7b67e39cd253724372d67da78221a38eca98d2a6b69027a89010bca2101dd02a` |

## PoC

| Field | Value |
|-------|--------|
| Folder | `2024-12-GemPadLock_exp` |
| Test | `test/GemPadLock_exp.sol` |
| Fork | Ethereum block **21420584** (pre-fix / Decurity educational block) |
| RPC used | `https://eth.drpc.org` (archive) |
| Offline anvil_state | not shipped (ONLINE archive) |

### Run

```bash
unset ETH_RPC_URL FOUNDRY_ETH_RPC_URL   # avoid non-archive override
cd 2024-12-GemPadLock_exp
forge test --match-contract GemPadLock_exp -vv --gas-limit 100000000
```

### Expected

- `free lockIds minted via reentrancy: > 0` (PoC logs 10)
- Attacker ETH balance increases after unlock + removeLiquidity (observed ~**+44 ETH** in this run)

## References

- TenArmor: https://x.com/TenArmorAlert/status/1869579224291623314
- Decurity deep dive + PoC source: https://blog.decurity.io/gempad-1-8m-incident-super-deep-dive-687cb4acb299
- Halborn: https://www.halborn.com/blog/post/explained-the-gempad-hack-december-2024
- pcaversaccio list: ETH victim/proxy + exploit tx

## Notes

- Fixed live code has `nonReentrant`; fork **must** be pre-upgrade.
- Teaching PoC reimplements Decurity’s malicious-token + UniV3 fee path (not byte-identical to attacker bytecode).
- Multi-chain: same proxy address pattern on BSC/Base; this folder ships ETH FOMO-LP path only.
