// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62968-cancelling-redeem-requests-permanently-blocks-the-withdrawal.sol";

contract AccountableQueueDeadlockTest is Test {
    function test_exploit_cancelHeadDeadlocksQueue() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.usedOnProcess(), 0, "process does nothing");
        assertEq(e.charlieClaimableAfter(), 0, "tail unclaimable");
        assertEq(e.charliePendingAfter(), 500e6, "tail still pending");
        assertEq(e.nextIdAfter(), 1, "nextRequestId stuck at deleted head");
    }
}
