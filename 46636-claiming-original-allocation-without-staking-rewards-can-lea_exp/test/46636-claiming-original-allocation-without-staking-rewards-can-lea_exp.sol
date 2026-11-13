// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, UsualSPFixed} from
    "./46636-claiming-original-allocation-without-staking-rewards-can-lea.sol";

contract Finding46636Test is Test {
    function test_exploit_claim_allocation_first_locks_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.owedBefore(), 100 ether, "owed");
        assertTrue(e.claimReverted(), "reverted");
        assertEq(e.stuck(), 100 ether, "stuck");
        assertEq(e.usualToken().balanceOf(address(e)), 0, "user");
        assertEq(e.usualS().balanceOf(address(e)), 100 ether, "principal");
    }

    function test_control_snapshot_before_allocation_pays_rewards() public {
        Token usualS = new Token("sUSUAL");
        Token usualToken = new Token("USUAL");
        UsualSPFixed stake = new UsualSPFixed(usualS, usualToken);
        stake.seed(address(this), 100 ether, 1e24);
        usualToken.mint(address(stake), 100 ether);
        stake.claimOriginalAllocation();
        uint256 paid = stake.claimReward();
        assertEq(paid, 100 ether, "paid");
        assertEq(usualToken.balanceOf(address(this)), 100 ether, "user");
        assertEq(usualToken.balanceOf(address(stake)), 0, "empty");
        assertEq(usualS.balanceOf(address(this)), 100 ether, "principal");
    }
}
