# Vulnerable contract `0x43Dc865E916914FD93540461FdE124484FBf8fAa` — UNVERIFIED

Etherscan reports this contract as **UNVERIFIED** (no published source), despite the
PoC header linking to `#code`. The analysis below is reconstructed from the deployed
EVM bytecode read at the fork block.

## Selectors present in the dispatcher

| Selector | Signature |
|----------|-----------|
| `0x0a1b0b91` | `erc20TransferFrom(address,address,address,uint256)` |
| `0x0e0c24c9` | `permit`-style helper (calls `permit(...)` then transfer) |
| `0x83850919` | wrapper (forwards into the same transfer path) |
| `0x3ccfd60b` | `withdraw()` |
| `0x12065fe0` | `getBalance()` |
| `0x893d20e8` | `getOwner()` |
| `0x3158952e` | `Claim()` (payable) |
| `0x570a8c5e` | helper |

## Embedded revert strings (extracted from bytecode)

- `"balance is 0"`
- `"transferFrom failed"`

## Reconstructed `erc20TransferFrom` (selector 0x0a1b0b91)

The bytecode block at `0x1e0` implements, in pseudo-Solidity:

```solidity
// NO access control — anyone may call
function erc20TransferFrom(address token, address to, address from, uint256 amount) external {
    if (amount == 0) {
        amount = IERC20(token).balanceOf(from);   // 0x70a08231 balanceOf(from)
        require(amount > 0, "balance is 0");
    }
    bool ok = IERC20(token).transferFrom(from, to, amount); // 0x23b872dd transferFrom(from,to,amount)
    require(ok, "transferFrom failed");
}
```

This matches the live trace exactly: called with `amount = 0`, it read the victim's
USDC balance (`14773350000`) and pulled the entire amount to the caller-supplied `to`.

The success of `transferFrom` depends on the **victim having approved this contract** on
the token. On-chain, the victim `0x3DADf003…` held an effectively-unlimited USDC
approval to `0x43Dc865E…` (allowance ≈ `1.158e60`).
