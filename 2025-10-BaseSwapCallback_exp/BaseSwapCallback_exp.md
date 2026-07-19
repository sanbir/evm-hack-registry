# BaseSwapCallback Exploit — Public `uniswapV3SwapCallback` Approval Drain

> **Vulnerability classes:** vuln/access-control/missing-auth · vuln/dependency/unsafe-external-call

> **Reproduction:** isolated Foundry project at [this project folder](.). Verbose run: [output.txt](output.txt).
> Victim is **unverified**; PoC spoofs a Uniswap V3 pool via a minimal `token0()` contract.

---

## Key info

| | |
|---|---|
| **Loss** | **~55.51 WETH (~$220K)** drained from a single approver |
| **Vulnerable contract** | [`0xE143b486ab0413Df0D6DAd2caf6d2f61CAC54730`](https://basescan.org/address/0xE143b486ab0413Df0D6DAd2caf6d2f61CAC54730) (unverified) |
| **Victim / approver** | [`0xc0fFeE479E4cD49eafBA87449225e17c53251226`](https://basescan.org/address/0xc0ffee479e4cd49eafba87449225e17c53251226) |
| **Attacker EOA** | [`0x2a49c6fd18bd111d51c4fffa6559be1d950b8eff`](https://basescan.org/address/0x2a49c6fd18bd111d51c4fffa6559be1d950b8eff) |
| **Attacker contract** | [`0xf1a3686f4D394E52d9fdF60132e46EBdCD231B01`](https://basescan.org/address/0xf1a3686f4d394e52d9fdf60132e46ebdcd231b01) |
| **Attack tx** | [`0x4449114ceaedd11e8f1363c5e53507198323a63cb6958dc26078fc016d0d4b27`](https://basescan.org/tx/0x4449114ceaedd11e8f1363c5e53507198323a63cb6958dc26078fc016d0d4b27) |
| **Chain / block / date** | Base / **37,487,849** (fork **37,487,848**) / ~Oct 30, 2025 |
| **Bug class** | Missing callback authentication — any contract that implements `token0()` can invoke `uniswapV3SwapCallback` and `transferFrom` prior approvers |

---

## TL;DR

An unverified Base router-like contract exposes `uniswapV3SwapCallback(int256,int256,bytes)` **without verifying that `msg.sender` is a real Uniswap V3 pool created by a trusted factory**.

Its only “auth” is effectively:

1. Call `msg.sender.token0()` (and related pool surface) so the caller *looks* like a pool.
2. Decode attacker-controlled `data` as `(payer, recipient)`.
3. `WETH.transferFrom(payer, msg.sender, amount0Delta)` when `amount0Delta > 0`.

Anyone who previously `approve`d the vulnerable contract can be drained by a one-line fake pool:

```solidity
function token0() external pure returns (address) { return WETH; }

function exploit(uint256 amount) external {
    bytes memory data = abi.encode(VICTIM, address(this));
    IVulnerable(VULN).uniswapV3SwapCallback(int256(amount), -1, data);
}
```

Live attacker used a MEV-style multicall bot and ~219 repeated ~0.253 WETH pulls (same encoding) totaling **55.51 WETH**. The PoC drains the full remaining balance in a single callback.

---

## Root cause

Correct Uniswap V3 integrators must authenticate the callback, e.g. via
`CallbackValidation.verifyCallback(factory, PoolAddress.PoolKey({...}))` so that
`msg.sender == factory.getPool(token0, token1, fee)`.

This contract either:

- omits factory verification entirely, or
- only checks that `msg.sender` responds to `token0()` / returns a non-zero token,

which is trivial to spoof. Combined with **arbitrary `payer` in callback `data`**, any residual ERC-20 allowance becomes freely stealable.

Observed pre-attack state (fork block 37,487,848):

| Parameter | Value |
|---|---|
| Victim WETH balance | **55.514876455905996937 WETH** |
| `allowance(victim, vuln)` | **~2,996 WETH** (far above balance) |
| Vulnerable code size | 5,591 bytes (unverified) |

---

## Attack steps (PoC)

1. Fork Base at `37487849 - 1`.
2. Deploy `FakePool` with `token0() → WETH`.
3. Call `uniswapV3SwapCallback(victimBal, -1, abi.encode(victim, fakePool))` from `FakePool`.
4. Vulnerable contract pulls full victim WETH into `FakePool` via `transferFrom`.
5. Sweep WETH to the attacker test contract.

---

## Fix class

- Require `msg.sender` is the canonical pool for the swap path (`CallbackValidation` / factory `getPool`).
- Never accept a user-controlled `payer` unless that user is `msg.sender` of the *initiating* swap and a reentrancy/lock flag proves an in-flight swap.
- Prefer pulling tokens in the outer function (before `pool.swap`) rather than in the callback from arbitrary payers.

---

## Sources

- [CertiKAlert](https://x.com/CertiKAlert/status/1983742817022439822)
- [SkyLens tx](https://skylens.certik.com/tx/base/0x4449114ceaedd11e8f1363c5e53507198323a63cb6958dc26078fc016d0d4b27)
