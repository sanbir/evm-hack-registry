// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RaToken, PsmFixed} from
    "./41481-h-7-wrong-accounting-of-locked-ra-when-repurchasing-dspa-wit.sol";

contract Finding41481Test is Test {
    function test_exploit_double_locked_fee_steals_3_ra() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.withdrawn(), 103 ether, "attacker redeemed 103");
        assertEq(e.ra().balanceOf(address(e)), 103 ether, "holds 103");
        assertEq(e.shortfall(), 3 ether, "victim short 3");
        assertEq(e.psm().locked(), 1103 ether, "locked");
        assertEq(e.ra().balanceOf(address(e.psm())), 997 ether, "997 left for 1000 owed");
    }

    function test_control_fee_is_not_locked_twice_and_victim_can_exit() public {
        RaToken ra = new RaToken();
        PsmFixed psm = new PsmFixed(ra);
        address victim = address(0xBEEF);
        ra.mint(address(psm), 1000 ether);
        ra.mint(address(this), 100 ether);
        psm.seed(victim, 1000 ether);
        ra.approve(address(psm), type(uint256).max);
        psm.repurchase(100 ether);
        uint256 got = psm.redeem(address(this));
        uint256 victimGot = psm.redeem(victim);

        assertEq(got, 100 ether, "buyer only gets the RA they added");
        assertEq(victimGot, 1000 ether, "victim exits in full");
        assertEq(ra.balanceOf(address(psm)), 0, "empty");
        assertEq(psm.locked(), 1100 ether, "no extra 3");
    }
}
