// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeWalker,
    FeeWalkerFixed,
    MiniToken,
    Node,
    Liq,
    Fees,
    FullMath
} from "./63178-h-12-missing-width-scaling-in-feewalkerup-non-visited-underc.sol";

contract MissingWidthScalingFeeWalkerTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MAKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant WIDTH = 8;

    function test_exploit_nonVisitedPath_undercreditsCompoundingMakerByWidth() public {
        Exploit e = new Exploit();
        e.run();

        // The buggy non-visited path credits only base*rate = 1000 * 1e15 = 1 ether.
        assertEq(e.buggyXCFees(), 1 ether, "buggy under-credit");
        // The correct (width-scaled) credit is width*base*rate = 8 * 1e18 = 8 ether.
        assertEq(e.correctXCFees(), 8 ether, "correct width-scaled credit");

        // Exact 1/width relationship (width=8 => buggy == correct/8).
        assertEq(e.buggyXCFees(), e.correctXCFees() / WIDTH, "buggy credit is exactly 1/width of correct");
        assertLt(e.buggyXCFees(), e.correctXCFees(), "maker credited less than earned");

        // The ~87.5% shortfall (7 ether of 8) is stranded / unclaimable.
        assertEq(e.shortfall(), 7 ether, "shortfall magnitude");
        assertEq(e.shortfall() * 8, e.correctXCFees() * 7, "shortfall == 87.5% of earned fee");

        // Real fee tokens: maker only received 1 ether; 7 ether remains stranded in the pool.
        MiniToken feeToken = e.feeToken();
        assertEq(feeToken.balanceOf(MAKER), 1 ether, "maker credited only the under-counted amount");
        assertEq(feeToken.balanceOf(e.feeWalkerAddr()), 0, "walker holds no tokens (stateless)");
        assertEq(e.strandedInPool(), 7 ether, "earned-but-unclaimable fee stranded in pool");

        // Loss marker records the stranded, unclaimable amount at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 7 ether, "LOST-FEE marker records shortfall at SINK");
    }

    function test_control_fixedPath_creditsFullWidthScaledFee() public {
        // Drive the FIXED walker with the IDENTICAL node/params; it must credit
        // the full width-scaled amount, leaving no shortfall.
        FeeWalker vuln = new FeeWalker();
        FeeWalkerFixed fixedWalker = new FeeWalkerFixed();

        uint256 rateX128 = uint256(1e15) * (uint256(1) << 128);
        Node memory node;
        node.liq = Liq({mLiq: 1200, ncLiq: 200}); // base = 1000

        Node memory buggyNode = vuln.up(node, WIDTH, 0, 0, rateX128, rateX128, 0);
        Node memory fixedNode = fixedWalker.up(node, WIDTH, 0, 0, rateX128, rateX128, 0);

        // Negative control: fixed credit == 8 * buggy credit == full earned fee.
        assertEq(buggyNode.fees.xCFees, 1 ether, "buggy path under-credits");
        assertEq(fixedNode.fees.xCFees, 8 ether, "fixed path credits full width-scaled fee");
        assertEq(fixedNode.fees.xCFees, buggyNode.fees.xCFees * WIDTH, "fix restores the width factor");

        // Same for the Y accumulator (both rates driven identically).
        assertEq(fixedNode.fees.yCFees, 8 ether, "fixed Y credit full");
        assertEq(buggyNode.fees.yCFees, 1 ether, "buggy Y credit under-counted");
    }

    function test_mulX128_double_isFaithfulQ128() public pure {
        // Sanity: the FullMath.mulX128 double is a real Q128.128 multiply.
        uint256 rateX128 = uint256(5) * (uint256(1) << 128); // 5.0 in Q128
        assertEq(FullMath.mulX128(rateX128, 1000, false), 5000, "5.0 * 1000 == 5000");
    }
}
