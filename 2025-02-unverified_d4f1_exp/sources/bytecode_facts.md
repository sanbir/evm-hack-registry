# On-chain facts for 0xD4F1AFD0331255e848c119CA39143D41144f7Cb3 (BSC, block 46681362)

All collected with `cast` against a BSC archive RPC at the fork block (46681362,
ts 1739625521 = 2025-02-15 13:18:41 UTC).

## Balances & state
| Item | Value |
|---|---|
| Native (BNB) balance | `23007026290916620075` wei = **23.00702629091662 BNB** |
| `getBalance()` (0x12065fe0) | `0x13f496083e028772b` = 23.007026290916617 BNB (returns `address(this).balance`) |
| `owner()` (0x8da5cb5b) | `0x0000...0000` (**zero — never initialized**) |
| OZ `Initializable` slot `0xf0c5..a00` | `0` (verified: `cast index-erc7201 "openzeppelin.storage.Initializable"`) |
| OZ `Ownable` slot `0x9016..300` | `0` (verified: `cast index-erc7201 "openzeppelin.storage.Ownable"`) |
| EIP-1967 impl slot | `0` (NOT a proxy — full 15.5 KB runtime bytecode) |
| EIP-1967 admin slot | `0` |
| `name()` / `symbol()` | empty (not an ERC20) |

## Function selectors found in the runtime dispatcher
| Selector | Signature | Role |
|---|---|---|
| 0x8129fc1c | `initialize()` | OZ initializer — leaves caller as owner |
| 0x8da5cb5b | `owner()` | OZ Ownable getter |
| 0x715018a6 | `renounceOwnership()` | OZ Ownable |
| 0xad3b1b47 | `withdrawFees(address,uint256)` | **onlyOwner BNB withdrawal — the drained function** |
| 0x12065fe0 | `getBalance()` | returns contract BNB |
| 0xad5c4648 | `WETH()` | router-style helper |
| 0x1d5f45f5 | `factoryV3()` | PancakeSwap V3 factory |
| 0x68e0d4e1 | `factoryV2()` | PancakeSwap V2 factory |
| 0x23a69e75 | `pancakeV3SwapCallback(int256,int256,bytes)` | V3 swap callback |
| 0xbc28ab43 | `getAmountsOut(uint256,address[],uint8)` | router quote helper |
| 0xd52bb6f4 | `getReserves(address,address)` | pair reserves helper |
| 0x53290b44 | `getBalanceOf(address,address)` | token balance helper |
| 0x9df90028 | `toggleContract()` | (likely on/off switch) |
| 0x3699530f, 0x595299b5, 0x5e56c50c, 0x8de4b786, 0x8f3fcc00, 0xaaa6b203, 0xb86a346e, 0xbc28ab43 | (swap/arb helpers, unresolved in 4byte) | |

Interpretation: a PancakeSwap V2/V3 **arbitrage / swap-helper bot** that accumulates
BNB profit and exposes an `onlyOwner withdrawFees()` to extract it. Built on OZ
upgradeable base contracts (`Initializable` + `OwnableUpgradeable`) but **deployed
without ever calling `initialize()`**.

## Real attack tx
`0xc7fc7e066ec2d4ea659061b75308c9016c0efab329d1055c2a8d91cc11dc3868`
- block 46681363, from `0xF30Be320c55038d7F784c561E56340439Dd1a283`, `to: null` (contract creation, nonce 1)
- The creation bytecode's constructor encodes:
  1. `call addr.initialize()`            (selector 0x8129fc1c)
  2. `call addr.withdrawFees(addr_self, addr_self.balance)` (selector 0xad3b1b47)
  3. forward `selfbalance` to `tx.origin` via `call{value}` (`...858888f1...`)
  then deploys a 0x42-byte stub runtime (`6080...36600a57005b00` = bare receive()).
