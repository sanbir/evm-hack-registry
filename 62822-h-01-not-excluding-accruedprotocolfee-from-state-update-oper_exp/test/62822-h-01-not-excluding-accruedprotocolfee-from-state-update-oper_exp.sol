// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    Covenant,
    CovenantFixed,
    MiniToken,
    RedeemParams
} from "./62822-h-01-not-excluding-accruedprotocolfee-from-state-update-oper.sol";

contract CovenantFullRedeemUnderflowTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant BASE_SUPPLY = 1_000_000 ether;
    uint256 internal constant Z_SUPPLY = 400_000 ether;
    uint256 internal constant A_SUPPLY = 600_000 ether;
    uint256 internal constant FEE_RATE_BP = 100; // 1%

    function test_exploit_fullRedeemUnderflows_baseSupplyLocked() public {
        Exploit e = new Exploit();
        e.run();

        // The full/last redeem reverted by underflow when protocol fees are on.
        assertTrue(e.fullRedeemReverted(), "full redeem should underflow-revert with fees on");

        // A non-zero fee was accrued (the trigger); the bug fires for ANY fee > 0.
        assertEq(e.expectedProtocolFee(), 10_000 ether, "1% fee on 1,000,000 base supply");

        // HARM: the entire base supply is permanently locked (unredeemable).
        assertEq(e.lockedBaseSupply(), BASE_SUPPLY, "full base supply remains locked");

        // The locked magnitude is recorded on the marker at the DoS SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), BASE_SUPPLY, "marker records locked base supply at SINK");
        assertEq(e.sinkMarkerBalance(), BASE_SUPPLY, "sink marker balance == locked base supply");

        // The vulnerable market's base supply was never reduced (redeem never succeeded).
        Covenant covenant = Covenant(e.covenantAddr());
        assertEq(covenant.baseSupplyOf(MARKET_ID), BASE_SUPPLY, "base supply untouched: redeem impossible");
    }

    function test_control_fixedExcludesFee_fullRedeemSucceeds() public {
        // Negative control: the recommended fix (exclude the fee from baseTokenSupply
        // before downstream use) makes the identical full redeem succeed.
        CovenantFixed covenant = new CovenantFixed();
        covenant.setProtocolFeeRate(FEE_RATE_BP);
        covenant.initMarket(MARKET_ID, BASE_SUPPLY, Z_SUPPLY, A_SUPPLY);

        RedeemParams memory rp =
            RedeemParams({marketId: MARKET_ID, aTokenAmountIn: A_SUPPLY, zTokenAmountIn: Z_SUPPLY});

        // Under the fix this does NOT revert...
        covenant.redeem(rp);

        // ...and the base supply is correctly driven to 0 (full redeem completed).
        assertEq(covenant.baseSupplyOf(MARKET_ID), 0, "fixed full redeem drives base supply to 0");
    }

    function test_control_feesOff_fullRedeemSucceedsOnVulnerable() public {
        // Second control: with fees OFF (protocolFees == 0) the SAME vulnerable
        // contract completes the full redeem — proving the fee accrual is the trigger.
        Covenant covenant = new Covenant();
        // protocolFeeRate stays 0 (governance has NOT turned fees on)
        covenant.initMarket(MARKET_ID, BASE_SUPPLY, Z_SUPPLY, A_SUPPLY);

        RedeemParams memory rp =
            RedeemParams({marketId: MARKET_ID, aTokenAmountIn: A_SUPPLY, zTokenAmountIn: Z_SUPPLY});

        covenant.redeem(rp); // no fee -> baseSupply - baseSupply - 0 == 0, no underflow
        assertEq(covenant.baseSupplyOf(MARKET_ID), 0, "with fees off, full redeem succeeds");
    }
}
