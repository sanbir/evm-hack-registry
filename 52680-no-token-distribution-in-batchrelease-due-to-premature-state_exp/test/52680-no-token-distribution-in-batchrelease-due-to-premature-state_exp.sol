// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./52680-no-token-distribution-in-batchrelease-due-to-premature-state.sol";

/*//////////////////////////////////////////////////////////////
    Treasury Vesting — batchRelease two-loop skips transfers (#52680)
//////////////////////////////////////////////////////////////*/
contract BatchReleaseNoDistributionTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vesting().totalReleased(), e.U1() + e.U2(), "accounting released");
        assertEq(e.token().balanceOf(address(e.user1())), 0, "user1 unpaid");
        assertEq(e.token().balanceOf(address(e.user2())), 0, "user2 unpaid");
    }
}
