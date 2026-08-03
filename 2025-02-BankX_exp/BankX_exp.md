# BankX Router — `swapXSDForETH` Reentrancy (BSC focus)

<!-- non-defihacklabs -->

> **Vulnerability classes:** vuln/reentrancy/single-function · vuln/logic/incorrect-state-transition

> **Reproduction:** Foundry PoC in [this project folder](.) — ONLINE BSC archive fork.
> Verbose run: [output.txt](output.txt). Router source: [sources/Router.sol](sources/Router.sol).

---

## Key info

| | |
|---|---|
| **Loss** | **~$43K** across BSC + ETH + Optimism |
| **Vulnerable contract** | BankX `Router` — [`0xaadae9117df8b5d584378a41a105cc4862a16e99`](https://bscscan.com/address/0xaadae9117df8b5d584378a41a105cc4862a16e99#code) (BSC) |
| **XSD/WETH pool** | [`0x8a4e0e2a778df8ce4ea5d5108fffe690cc9ae07a`](https://bscscan.com/address/0x8a4e0e2a778df8ce4ea5d5108fffe690cc9ae07a) |
| **XSD** | [`0x39400e67820c88a9d67f4f9c1fbf86f3d688e9f6`](https://bscscan.com/address/0x39400e67820c88a9d67f4f9c1fbf86f3d688e9f6) |
| **Attacker EOA (BSC)** | [`0x867aa2a2667060096d0f108ddfa3367caca9fd34`](https://bscscan.com/address/0x867aa2a2667060096d0f108ddfa3367caca9fd34) |
| **Attack contract (BSC)** | [`0xab50cfdab8484e15fee82852c08eec135ac00e4c`](https://bscscan.com/address/0xab50cfdab8484e15fee82852c08eec135ac00e4c) |
| **Attack txs** | [BSC](https://bscscan.com/tx/0xe808330b8ddc2f7c6164743c210c9e1975de87c1949c6353d98f2d39e4dde182) · [ETH](https://etherscan.io/tx/0xcec091760cac239afb912396b53f778a3710d14ab05ca810c285fe31fa70ede6) · [OP](https://optimistic.etherscan.io/tx/0xe1a3d0ddce6a075ee424fe0d0b87b465b363c2f26ca855b646296058f89b0c31) |
| **Chain / block / date** | BSC / **46,433,152** (fork 46,433,151) / Feb 8, 2025 |
| **Bug class** | ETH refund before XSD burn + full `amountInMax` transfer |

---

## TL;DR

`swapXSDForETH` pulls **`amountInMax` XSD** into the pool (not the quoted amount), swaps WETH out,
unwraps, and **`safeTransferETH`s to `msg.sender` before `burnpoolXSD(amountInMax/10)`**.

A contract attacker reenters on `receive()` while `pid_controller` still has `pricecheck=true`
(setPriceCheck runs only after the outer body), performing additional swaps against a desynced pool
and burning large XSD from the pool balance.

PoC: `priceCheck()` → wait `block_delay` (2) → reentrant `swapXSDForETH` → **7 BNB** out
(5 primary + 2 reentered) with `reenterCount=2`.

---

## Vulnerable code

```solidity
function swapXSDForETH(uint amountOut, uint amountInMax, uint deadline) external ... {
    (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool_address).getReserves();
    uint amounts = BankXLibrary.quote(amountOut, reserveB, reserveA);
    require(amounts <= amountInMax, 'BankXRouter: EXCESSIVE_INPUT_AMOUNT');
    TransferHelper.safeTransferFrom(xsd_address, msg.sender, XSDWETH_pool_address, amountInMax);
    IXSDWETHpool(XSDWETH_pool_address).swap(0, amountOut, address(this));
    IWBNB(WETH).withdraw(amountOut);
    TransferHelper.safeTransferETH(msg.sender, amountOut); // ← reentrancy
    if (... ) {
        XSD.burnpoolXSD(amountInMax/10); // ← after external call; uses full amountInMax
    }
}
```

---

## PoC notes

```bash
BSC_RPC_URL=https://bsc-mainnet.public.blastapi.io forge test --match-contract BankX_exp -vv
```

- Requires PID `priceCheck()` then `vm.roll(+block_delay)`.
- ONLINE only (no anvil_state).
- Demonstrates reentrancy multi-swap; live attack optimized amounts across 3 chains.

---

## References

- TenArmor: https://x.com/TenArmorAlert/status/1888141223094821215
