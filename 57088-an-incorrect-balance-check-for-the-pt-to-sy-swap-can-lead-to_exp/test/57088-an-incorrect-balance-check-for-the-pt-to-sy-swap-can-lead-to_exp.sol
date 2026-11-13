// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Mini, AMMFixed} from "./57088-an-incorrect-balance-check-for-the-pt-to-sy-swap-can-lead-to.sol";

contract Finding57088Test is Test {
    function test_exploit_takes_pt_and_pays_no_sy() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.availableSy(), 100 ether, "only 100 SY is unlocked");
        assertEq(e.checkPassed(), 1, "the total-supply check let 200 through");
        assertEq(e.ptTaken(), 200 ether, "200 PT moved into the pool");
        assertEq(e.syReceived(), 0, "user received no SY");
        assertEq(e.ptLeftOnUser(), 0, "user lost the 200 PT");
    }

    function test_control_rejects_before_taking_pt() public {
        Mini sy = new Mini("SY", "SY");
        Mini pt = new Mini("PT", "PT");
        AMMFixed amm = new AMMFixed(sy, pt);
        sy.mint(address(this), 1_000 ether);
        pt.mint(address(this), 200 ether);
        sy.approve(address(amm), 1_000 ether);
        pt.approve(address(amm), 200 ether);
        amm.seed(1_000 ether, 900 ether);

        uint256 syOut = amm.handle_swap_pt_for_sy(200 ether, 1 ether);
        assertEq(syOut, 0, "swap rejected");
        assertEq(pt.balanceOf(address(this)), 200 ether, "user keeps 200 PT");
        assertEq(pt.balanceOf(address(amm)), 0, "pool took no PT");
        assertEq(sy.balanceOf(address(this)), 0, "no SY paid from the locked reserve");
    }
}
