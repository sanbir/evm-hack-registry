// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    MockToken,
    Recipient,
    BaseMilestone
} from "./47910-locked-tokens-in-milestone-contract-ottersec-none-vtvl-pdf.sol";

contract VtvlMilestoneLockTest is Test {
    function test_exploit_remaining_allocation_cannot_be_withdrawn() public {
        Exploit e = new Exploit();
        e.run();

        uint256 stuck = e.token().balanceOf(address(e.milestone()));
        uint256 paid = e.token().balanceOf(address(e.alice()));
        console.log("tokens stuck in milestone", stuck);
        console.log("tokens paid to first recipient", paid);
        assertEq(stuck, 100 ether, "100 tokens stuck");
        assertEq(paid, 100 ether, "alice was paid 100");
        assertFalse(e.milestone().isComplete(address(e.bob())), "bob cannot be completed");
        assertEq(e.token().balanceOf(address(e.bob())), 0, "bob received nothing");
    }

    function test_control_counting_withdrawals_releases_the_remainder() public {
        MockToken token = new MockToken("VTVL", "VTVL", 18);
        Recipient alice = new Recipient();
        Recipient bob = new Recipient();
        address[] memory who = new address[](2);
        who[0] = address(alice);
        who[1] = address(bob);
        BaseMilestone milestone = new BaseMilestone(token, 100 ether, who);
        token.mint(address(this), 200 ether);
        token.transfer(address(milestone), 200 ether);

        milestone.setComplete(address(alice));
        milestone.withdraw(address(alice));

        // The vulnerable check now reverts: balance 100 < 200.
        vm.expectRevert(bytes("NOT_DEPOSITED"));
        milestone.setComplete(address(bob));

        // The fix adds withdrawals back, so the original 200 still covers both allocations.
        milestone.setCompleteFixed(address(bob));
        milestone.withdraw(address(bob));
        assertEq(token.balanceOf(address(milestone)), 0, "fix releases the stuck 100");
        assertEq(token.balanceOf(address(bob)), 100 ether, "bob receives 100");
        assertEq(token.balanceOf(address(alice)), 100 ether, "alice keeps 100");
    }
}
