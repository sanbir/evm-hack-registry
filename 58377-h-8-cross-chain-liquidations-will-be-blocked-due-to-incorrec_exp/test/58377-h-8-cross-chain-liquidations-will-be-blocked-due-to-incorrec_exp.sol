// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendStorage} from "./58377-h-8-cross-chain-liquidations-will-be-blocked-due-to-incorrec.sol";

contract Finding58377Test is Test {
    function test_exploit_cross_chain_liquidation_cap_is_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.maxRepay(), 0, "cap");
        assertTrue(e.liquidationBlocked(), "blocked");
        assertEq(e.realDebt(), 1000 ether, "debt");
        assertEq(e.collateralStillSeizable(), 1000 ether, "collateral");
    }

    function test_control_destination_borrows_allow_half_repay() public {
        Exploit e = new Exploit();
        e.run();

        uint256 fixedCap = e.vuln().maxRepayCountingDestination(e.borrower(), address(e.lToken()));
        assertEq(fixedCap, 500 ether, "fixed cap");
        assertGt(fixedCap, e.maxRepay(), "fixed cap above broken cap");
    }
}
