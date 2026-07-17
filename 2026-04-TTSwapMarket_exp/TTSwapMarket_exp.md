# TTSwap Market: permissionless `initGood` + attacker-controlled ERC20 skews AMM accounting via `buyGood`/`payGood`

> **Vulnerability classes:** vuln/logic/incorrect-initialization · vuln/logic/missing-check · vuln/oracle/price-manipulation

> **Reproduction:** the PoC compiles & runs in an isolated Foundry project at
> [this project folder](.). The fork is served offline from the bundled
> `anvil_state.json` (local anvil replays Ethereum state at block `24991800`), so no
> public RPC is required.
> Full verbose trace: [output.txt](output.txt).
> Verified market implementation: [src_TTSwap_Market.sol](sources/TTSwap_Market/TTSwap_Market_979041/src_TTSwap_Market.sol).
> Proxy: [TTSwap_Market_Proxy](sources/TTSwap_Market_Proxy/TTSwap_Market_Proxy_5c70a4/).
> Swap math library: [L_Good.sol](sources/TTSwap_Market/TTSwap_Market_979041/src_libraries_L_Good.sol).

<!-- non-defihacklabs -->

---

## Key info

| | |
|---|---|
| **Loss** | **5.098626217469779632 ETH** (exact PoC / on-chain profit after 8 WETH Balancer repay) |
| **Vulnerable contract** | TTSwap Market proxy — [`0x5C70a413fcb7ea8c8D478D06F31f8963cE4EE635`](https://etherscan.io/address/0x5c70a413fcb7ea8c8d478d06f31f8963ce4ee635) |
| **Implementation** | [`0x97904142f8d4dfa3e54011cf5dc19dbcaf5dd6a6`](https://etherscan.io/address/0x97904142f8d4dfa3e54011cf5dc19dbcaf5dd6a6#code) |
| **Fake good token (attacker CREATE)** | [`0xEefFdB5fCED045EFbaa7293f2D2Eff5EcfBE9A26`](https://etherscan.io/address/0xeeffdb5fced045efbaa7293f2d2eff5ecfbe9a26) |
| **Attacker EOA** | [`0x12494E12A20267c52c445765e9c204CDa7e7A02e`](https://etherscan.io/address/0x12494e12a20267c52c445765e9c204cda7e7a02e) |
| **Attack factory** | [`0x5d5Fc1C6156F8c5EEA8E7FE2649507F0CE6bFc1B`](https://etherscan.io/address/0x5d5fc1c6156f8c5eea8e7fe2649507f0ce6bfc1b) (CREATE, nonce 0) |
| **Child exploit** | [`0x91Ae7aDeA5153229910B5C379A8C7561aD70B144`](https://etherscan.io/address/0x91ae7adea5153229910b5c379a8c7561ad70b144) |
| **Balancer Vault (FL)** | [`0xBA12222222228d8Ba445958a75a0704d566BF2C8`](https://etherscan.io/address/0xba12222222228d8ba445958a75a0704d566bf2c8) |
| **Attack tx** | [`0x43a0161de17f23e8767e736cce39c87bcc4de5e6504a23c98899427f760ee343`](https://etherscan.io/tx/0x43a0161de17f23e8767e736cce39c87bcc4de5e6504a23c98899427f760ee343) |
| **Chain / block / date** | Ethereum mainnet / fork `24991800` (attack in `24991801`) / 2026-04-30 |
| **Bug class** | Permissionless market `initGood` with attacker-controlled ERC20 + value/quantity AMM seeding → mispriced `buyGood`/`payGood` inventory drain |

---

## Naming / TesseraSwap (important)

**This is not TesseraSwap.**

| | TTSwap Market (this entry) | TesseraSwap (`2026-05-TesseraSwap_exp`) |
|---|---|---|
| Chain | Ethereum | Base |
| Victim | TTSwap Market singleton AMM | Tessera treasury swap router |
| Bug | Market init + buy/pay accounting | CEI: pay output before collect input |
| Profit | ~5.1 ETH | ~13k USDC / loop campaign |

ExVul alert: [status/2049788573554229599](https://x.com/exvulsec/status/2049788573554229599).

---

## TL;DR

1. Attacker CREATE-deploys a factory (nonce 0) that spawns a child exploit and a **fake ERC20 good** (spoofed `transfer`/`balanceOf`).
2. Child flash-loans **8 WETH** from Balancer, then calls permissionless `initGood(WETH, packed, fake, goodConfig, …)` so the market seeds a new good pair using attacker-chosen quantity and WETH value deposit.
3. Because the fake token fabricates successful transfers of arbitrary quantities, internal `currentState` / `investState` (value vs quantity) can be skewed relative to real inventory of existing goods.
4. Repeated `buyGood` / `payGood` against market inventory extract USDT, USDC, WBTC, BNB, SOL, and residual WETH at broken rates; tokens are swapped to WETH on Uni v2/v3, the 8 WETH loan is repaid, and **5.098626217469779632 ETH** is kept.

---

## Root cause

### Permissionless `initGood` with attacker-controlled ERC20

`initGood` is **not** admin-gated (`guardedEntry` reentrancy only). Any caller may register a new good by supplying:

- `_valuegood` — an existing value good (WETH)
- `_erc20address` — the new "normal" good (attacker CREATE fake token)
- `_initial` packed uint256 — amount0 = normal qty, amount1 = value-good qty
- `_goodConfig` — fee/K parameters for the new good

```solidity
// sources/.../src_TTSwap_Market.sol (verified impl)
function initGood(
    address _valuegood,
    uint256 _initial,
    address _erc20address,
    uint256 _goodConfig,
    bytes calldata _normaldata,
    bytes calldata _valuedata,
    address _trader,
    bytes calldata signature
) external payable override guardedEntry msgValue returns (bool) {
    _checkTrader(_trader);
    // min qty check only — no token allowlist / no real-supply verification
    if (_initial.amount0() < 500000 || _initial.amount0() > 2 ** 109)
        revert TTSwapError(36);
    ...
    _erc20address.transferFrom(msg.sender, msg.sender, _initial.amount0(), _normaldata);
    _valuegood.transferFrom(msg.sender, msg.sender, _initial.amount1(), _valuedata);
    ...
    goods[_valuegood].investGood(_initial.amount1(), investResult, 100);
    goods[_erc20address].init(
        toTTSwapUINT256(investResult.investValue, _initial.amount0()),
        _goodConfig
    );
}
```

The fake ERC20 returns success for any `transferFrom` and reports inflated balances. Real WETH still moves into the market, but the **normal-good quantity side is attacker-chosen fiction**.

### AMM state seeds from that init

`L_Good.init` sets both current quantity and invest value from the packed `_init`:

```solidity
// L_Good.sol
self.currentState = toTTSwapUINT256(_init.amount1(), _init.amount1()); // qty
self.investState  = toTTSwapUINT256(_init.amount1(), _init.amount0()); // value
```

Subsequent `good1Swap` / `good2Swap` price trades from `current_quantity` and `current_value`:

```
ΔV = (K * V * Δa) / (K * Q + Δa * 10000)   // good1Swap input
Δb = (K * Q * ΔV) / (K * V + ΔV * 10000)   // good2Swap output
```

With skewed (V, Q) on the fake good (and paired value-good depth changes from the WETH invest), `buyGood` / `payGood` emit real market inventory against the synthetic good at rates the attacker controls.

### Why Balancer 8 WETH

Flash capital funds the value-good leg of `initGood` and intermediate swap inventory. After draining multi-token market balances and routing them to WETH, the loan is repaid and residual native ETH is profit.

---

## Attack path

```mermaid
sequenceDiagram
    participant A as Attacker EOA
    participant F as Factory 0x5d5f…
    participant C as Child 0x91Ae…
    participant Fake as Fake good 0xEefF…
    participant B as Balancer Vault
    participant M as TTSwap Market
    participant Uni as Uni v2/v3

    A->>F: CREATE (nonce 0)
    F->>C: CREATE child
    F->>Fake: CREATE fake ERC20
    C->>B: flashLoan 8 WETH
    B->>C: 8 WETH
    C->>M: approve + initGood(WETH, packed, Fake, config)
    Note over M: Fake transferFrom "succeeds"; WETH real deposit seeds value
    loop buyGood / payGood
        C->>M: swap Fake vs inventory goods
        M-->>C: USDT/USDC/WBTC/BNB/SOL/WETH
    end
    C->>Uni: drain tokens → WETH
    C->>B: repay 8 WETH
    C->>F: residual ETH
    F->>A: 5.098626217469779632 ETH
```

### Funds (historical)

| Flow | Amount |
|---|---|
| Balancer FL | 8 WETH |
| Market multi-asset drain → WETH legs | USDT 3,595.52 · USDC 1,851.03 · WBTC 0.025 · BNB 1.32 · SOL 7.029 · residual WETH |
| Net to attacker EOA | **5.098626217469779632 ETH** |

---

## PoC

### CREATE replay (primary)

`test/TTSwapMarket_exp.sol` replays the full historical CREATE initcode at fork block `24991800` (attacker nonce forced to 0 → factory `0x5d5Fc1…`). Constructor tree performs FL + init + drain + repay.

### Playground synthetic

`test/2026-04-TTSwapMarket.sol` wraps the same initcode in `attack()` and forwards ETH to `owner`.

```bash
# Offline (bundled anvil_state.json)
bash _shared/run_poc.sh 2026-04-TTSwapMarket_exp -vv
```

Exact assert: `profit == 5_098_626_217_469_779_632` wei ETH.

---

## Mitigation notes

1. **Do not allow untrusted ERC20s as goods** without a registry/allowlist or deposit verification against real `balanceOf` deltas (and preferably transfer tax / fee-on-transfer guards).
2. Gate `initGood` (or require a bonded stake / admin/oracle-approved listing) so attacker-controlled tokens cannot seed AMM (V, Q) state.
3. After any transferFrom into the market, **reconcile balance deltas** rather than trusting the caller-supplied quantity parameter.
4. Cap `goodConfig` parameters and reject configs that create extreme V/Q ratios relative to observed external prices.

---

## References

- ExVul: https://x.com/exvulsec/status/2049788573554229599
- Attack tx: https://etherscan.io/tx/0x43a0161de17f23e8767e736cce39c87bcc4de5e6504a23c98899427f760ee343
- Market proxy: https://etherscan.io/address/0x5c70a413fcb7ea8c8d478d06f31f8963ce4ee635
- Impl: https://etherscan.io/address/0x97904142f8d4dfa3e54011cf5dc19dbcaf5dd6a6#code
- Upstream (similar surface): https://github.com/tt-swap/ttswap-core-v1
