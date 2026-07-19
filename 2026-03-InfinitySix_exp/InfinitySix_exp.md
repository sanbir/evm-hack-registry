# InfinitySix — Stale 1-min TWAP + Instant Referral Bonus Over-Mint

> **Vulnerability classes:** vuln/oracle/price-manipulation · vuln/logic/incorrect-calculation

> **Reproduction:** Foundry PoC in [this project folder](.) — ONLINE archive fork (BSC).
> Verbose run: [output.txt](output.txt). Verified source: [sources/InfinitySix.sol](sources/InfinitySix.sol).

---

## Key info

| | |
|---|---|
| **Loss** | **~$273.8K USDT** attacker profit (PoC net ~$277.2K without flash fees) |
| **Vulnerable contract** | InfinitySix (direct) — [`0x1cb36b0f1efd9b738997da3d5525364c7e82a18a`](https://bscscan.com/address/0x1cb36b0f1efd9b738997da3d5525364c7e82a18a#code) |
| **i6 token** | [`0xd7684971afe4c231fa9af6b53e18eaf86438a0e6`](https://bscscan.com/address/0xd7684971afe4c231fa9af6b53e18eaf86438a0e6) |
| **USDT** | [`0x55d398326f99059ff775485246999027b3197955`](https://bscscan.com/address/0x55d398326f99059ff775485246999027b3197955) |
| **i6/USDT pair** | [`0xdc769f4d941408ab5c12db981e50ed3e69357e36`](https://bscscan.com/address/0xdc769f4d941408ab5c12db981e50ed3e69357e36) |
| **Attacker EOA** | [`0x6d1cafc890cc7dd6bf3718453367f8e0fd9851e4`](https://bscscan.com/address/0x6d1cafc890cc7dd6bf3718453367f8e0fd9851e4) |
| **Attack contract** | [`0xb38cba2562b70309fc19d06b6b0468c8fd89b025`](https://bscscan.com/address/0xb38cba2562b70309fc19d06b6b0468c8fd89b025) |
| **Attack tx** | [`0xc1b9a237…ab2f16`](https://bscscan.com/tx/0xc1b9a237a00b53a595e1e2d0d93841154ddcdf9aa217be8f395449b8e4ab2f16) |
| **Chain / block / date** | BSC / **89,703,286** (fork at 89,703,285) / Mar 31, 2026 |
| **Bug class** | Instant `directBonus` + same-tx stale TWAP settlement |

---

## TL;DR

`invest()` immediately credits the sponsor with `directBonus += 5%` of the invest amount.
`withdraw()` pays that USDT-denominated bonus in **i6 tokens priced by `twapPrice`**, but
`updateTwap()` **refuses to update more than once per minute**. Inside one transaction the
attacker:

1. Does a small self-invest under `GENESIS_USER` (locks TWAP ≈ **1.05 USDT/i6**).
2. Routes ~**$124M USDT** through a helper that invests with the attacker as referrer →
   **~$6.2M directBonus** + floods the LP (spot ≈ **15,528**).
3. Calls `withdraw()` — TWAP still ~1.05 → mints **~5.6M i6** from the project reserve
   (fair amount at spot would be ~399 i6).
4. Dumps i6 into the USDT-heavy LP for **~$125.2M**, repays capital, keeps **~$274K**.

---

## Vulnerable code

### Instant referral bonus ([sources/InfinitySix.sol](sources/InfinitySix.sol))

```solidity
if (user.referrer != address(0)) {
    User storage refUser = users[user.referrer];
    if (!refUser.isCapped) {
        refUser.directBonus += (usdtAmount * DIRECT_BONUS_RATE) / 1000; // 5%, immediate
    }
}
```

### Stale TWAP floor

```solidity
uint32 public constant TWAP_UPDATE_INTERVAL = 1 minutes;

function updateTwap() public {
    // ...
    if (timeSinceLastUpdate < TWAP_UPDATE_INTERVAL) return; // same-tx: always early-return
    // ...
}

function withdraw() external nonReentrant {
    if (uniswapPair != address(0)) { updateTwap(); }
    // ...
    uint256 effectivePrice = twapPrice > minTwapPrice ? twapPrice : minTwapPrice;
    uint256 tokensToTransfer = (totalUsdtToWithdraw * WAD) / effectivePrice;
    // transfer i6 to msg.sender (minus 5% burn)
}
```

The sponsor’s 7× payout cap is sized so `sponsorInvest * 7 ≈ referralInvest * 5%`
(885,815.60 × 7 = 6,200,709.20 = 5% of 124,014,184.40).

---

## Attack flow

```mermaid
sequenceDiagram
    participant A as Attacker
    participant H as Referral helper
    participant I as InfinitySix
    participant LP as Pancake i6/USDT

    A->>I: invest(885.8k USDT, GENESIS)
    Note over I: TWAP observation ~1.05
    A->>H: fund 124M USDT
    H->>I: invest(124M, sponsor=A)
    Note over I: directBonus[A]+=6.2M; LP spot→15k
    A->>I: withdraw()
    Note over I: updateTwap early-return; pay ~5.6M i6 @ 1.05
    A->>LP: dump i6 → ~125.2M USDT
    Note over A: net ~$274K after capital return
```

---

## PoC notes

- ONLINE fork via `BSC_RPC_URL` (default `https://bsc-mainnet.public.blastapi.io`).
- Capital is `deal`’d USDT (live attack used Moolah WBNB flash → Venus → PancakeV3 flash).
- Run: `BSC_RPC_URL=... forge test --match-contract InfinitySix_exp -vv`
- Expected: `[PASS]`, net profit **> 100k USDT** (observed ~277k).

Offline `anvil_state.json` not shipped (large multi-protocol state; ONLINE only).

---

## References

- ExVul: https://x.com/exvulsec/status/2038823338034987369
- DarkNavy write-up: https://www.darknavy.org/web3/exploits/infinitysix-twap-stale-price/
