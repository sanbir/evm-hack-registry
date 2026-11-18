// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, ZeremVault} from
    "./20308-h-01-the-unlockexponent-does-not-work-as-intended-when-it-is.sol";

contract Finding20308Test is Test {
    uint256 constant TOTAL = 1e18;

    function test_exploit_exponent_zero_locks_all_but_one_over_precision() public {
        Exploit e = new Exploit();
        e.run();

        uint256 paid = TOTAL / 1e8;
        assertEq(e.token().balanceOf(address(e)), paid, "claimer got total/1e8");
        assertEq(e.token().balanceOf(address(e.vault())), TOTAL - paid, "rest stuck in vault");
        assertEq(e.vault().claimed(), paid, "second claim would pay 0");
    }

    function test_control_exponent_one_unlocks_full_balance_after_the_period() public {
        Token token = new Token();
        ZeremVault linear = new ZeremVault(token, 1);
        token.mint(address(this), TOTAL);
        token.approve(address(linear), TOTAL);
        linear.lock(TOTAL);

        vm.warp(block.timestamp + linear.unlockPeriodSec());
        uint256 paid = linear.claim();

        assertEq(paid, TOTAL, "linear exponent unlocks 100%");
        assertEq(token.balanceOf(address(linear)), 0, "vault empty");
        assertEq(token.balanceOf(address(this)), TOTAL, "holder received all");
    }

    function test_control_exponent_zero_still_stuck_after_the_full_period() public {
        Token token = new Token();
        ZeremVault stuckVault = new ZeremVault(token, 0);
        token.mint(address(this), TOTAL);
        token.approve(address(stuckVault), TOTAL);
        stuckVault.lock(TOTAL);

        vm.warp(block.timestamp + stuckVault.unlockPeriodSec());
        uint256 paid = stuckVault.claim();

        assertEq(paid, TOTAL / 1e8, "full delay does not help exponent 0");
        assertEq(token.balanceOf(address(stuckVault)), TOTAL - paid, "still stuck");
    }
}
