// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeToken,
    OmoOracleFixed,
    PositionManager
} from "./53330-h-12-getpositionvalue-does-not-consider-accumulated-fees-pas.sol";

contract Finding53330Test is Test {
    function test_exploit_liquidation_is_short_the_fees() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.reported(), 1000, "reported 1000");
        assertEq(e.seized(), 250, "250 fees seized");
        assertTrue(e.didLiquidate(), "liquidated");
        assertEq(e.fees().balanceOf(address(this)), 250, "liquidator received the fees");
        assertLt(uint256(1100), e.reported() + 250, "true value covers the debt");
    }

    function test_control_including_fees_does_not_liquidate() public {
        FeeToken fees = new FeeToken();
        PositionManager pm = new PositionManager(address(fees), address(fees));
        OmoOracleFixed oracle = new OmoOracleFixed();
        uint256 value = oracle.getPositionValue(address(pm), 1, address(fees));
        assertEq(value, 1250, "fees included");
        assertGt(value, 1100, "debt is covered");
        assertEq(fees.balanceOf(address(this)), 0, "control seizes nothing");
    }
}
