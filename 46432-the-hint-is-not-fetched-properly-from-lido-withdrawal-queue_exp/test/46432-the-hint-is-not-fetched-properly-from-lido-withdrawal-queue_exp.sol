// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, WithdrawalQueue} from
    "./46432-the-hint-is-not-fetched-properly-from-lido-withdrawal-queue.sol";

contract Finding46432Test is Test {
    function test_exploit_short_hint_range_locks_the_eth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.eth().balanceOf(address(e.queue())), 1 ether, "queue still holds 1 ETH");
        assertEq(e.eth().balanceOf(address(e.user())), 0, "user received 0");
        assertFalse(e.queue().claimed(), "not claimed");
    }

    function test_control_last_checkpoint_index_pays_the_eth() public {
        Exploit e = new Exploit();
        e.run();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 59498;
        uint256[] memory hints =
            e.queue().findCheckpointHints(ids, 1, e.queue().getLastCheckpointIndex());
        assertEq(hints[0], 555, "hint 555");

        e.queue().claimWithdrawalsTo(ids, hints, address(this));
        assertEq(e.eth().balanceOf(address(this)), 1 ether, "control paid 1 ETH");
        assertEq(e.eth().balanceOf(address(e.queue())), 0, "queue empty");
    }
}
