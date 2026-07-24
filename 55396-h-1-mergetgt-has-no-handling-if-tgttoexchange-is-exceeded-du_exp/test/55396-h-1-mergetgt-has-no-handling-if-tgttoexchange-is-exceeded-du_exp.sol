// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55396-h-1-mergetgt-has-no-handling-if-tgttoexchange-is-exceeded-du.sol";

contract MergeTgtOverSubscribeTest is Test {
    function test_late_claimer_cannot_claim_when_tgt_exceeds_cap() public {
        Exploit exp = new Exploit();
        MergeTgt merge = exp.merge();
        UserActor user1 = exp.user1();
        UserActor user2 = exp.user2();
        MockERC20 titn = exp.titn();

        exp.run();

        assertGt(titn.balanceOf(address(user2)), 0, "early claimer got TITN");
        assertEq(titn.balanceOf(address(user1)), 0, "late claimer got nothing");
        assertGt(merge.claimableTitnPerUser(address(user1)), 0, "claimable still booked for user1");
        assertEq(exp.tgt().balanceOf(address(merge)), exp.U1_TGT() + exp.U2_TGT(), "TGT stuck");
    }
}
