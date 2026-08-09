// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    ElytraOracleV1,
    ElytraOracleV1Fixed,
    MiniToken
} from "./63546-h-03-scaling-error-in-elyasset-price-calculation-leads-to-fe.sol";

contract ElytraScalingFeeLossTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant OLD_PRICE = 1e18;
    uint256 internal constant TOTAL_VALUE = 2000e18;
    uint256 internal constant ELY_SUPPLY = 1000e18;
    uint256 internal constant FEE_BPS = 1000;

    function test_exploit_scalingError_zeroesProtocolFee() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy price calc collapses tempElyAssetPrice to 2 (< oldElyAssetPrice
        // 1e18), so the reward/fee branch never fires and no fee is accrued.
        assertEq(e.vulnFee(), 0, "vulnerable code accrues zero protocol fee");

        // On identical inputs, the correctly-scaled price (2e18 > 1e18) fires the
        // branch and accrues a 100e18 performance fee.
        assertEq(e.correctFee(), 100e18, "fixed code accrues the owed 100e18 fee");

        // HARM: 100e18 of protocol performance fee is permanently uncollected.
        assertGt(e.correctFee(), e.vulnFee(), "protocol collects less than entitled");
        assertEq(e.foregoneFee(), 100e18, "foregone-fee magnitude");

        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 100e18, "marker records foregone fee at SINK");
    }

    function test_control_directOracleCall_confirmsBugAndFix() public {
        // Verify the harm holds when the REAL vulnerable contract is driven
        // directly (independent of the Exploit wrapper), with a negative control.
        ElytraOracleV1 vuln = new ElytraOracleV1(OLD_PRICE, FEE_BPS);
        vuln.updateElyAssetPrice(TOTAL_VALUE, ELY_SUPPLY);
        assertEq(vuln.lastProtocolFeeInHYPE(), 0, "buggy oracle: zero fee");

        ElytraOracleV1Fixed fixedOracle = new ElytraOracleV1Fixed(OLD_PRICE, FEE_BPS);
        fixedOracle.updateElyAssetPrice(TOTAL_VALUE, ELY_SUPPLY);
        assertEq(fixedOracle.lastProtocolFeeInHYPE(), 100e18, "fixed oracle: 100e18 fee");
    }
}
