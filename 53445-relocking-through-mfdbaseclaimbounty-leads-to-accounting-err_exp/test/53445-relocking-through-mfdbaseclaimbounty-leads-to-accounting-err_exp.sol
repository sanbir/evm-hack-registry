// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LpToken, Gauge, MFDBaseFixed} from
    "./53445-relocking-through-mfdbaseclaimbounty-leads-to-accounting-err.sol";

contract Finding53445Test is Test {
    function test_exploit_relock_locks_lp_tokens() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.withdrawReverted(), "revert");
        assertEq(e.stuck(), 100 ether, "stuck");
        assertEq(e.gauge().balanceOf(address(e.staker())), 0, "gauge");
        assertEq(e.lp().balanceOf(address(e)), 0, "user");
    }

    function test_control_restake_lets_user_withdraw() public {
        LpToken lp = new LpToken();
        Gauge gauge = new Gauge(lp);
        MFDBaseFixed fixedS = new MFDBaseFixed(lp, gauge);
        lp.mint(address(this), 100 ether);
        lp.approve(address(fixedS), 100 ether);
        fixedS.stake(100 ether);
        fixedS.setAutoRelock(true);
        fixedS.claimBounty(address(this), true);
        assertEq(gauge.balanceOf(address(fixedS)), 100 ether, "restaked");
        fixedS.withdrawExpiredLocks();
        assertEq(lp.balanceOf(address(this)), 100 ether, "returned");
        assertEq(fixedS.locked(address(this)), 0, "cleared");
        assertEq(gauge.balanceOf(address(fixedS)), 0, "gauge empty after real withdraw");
    }
}
