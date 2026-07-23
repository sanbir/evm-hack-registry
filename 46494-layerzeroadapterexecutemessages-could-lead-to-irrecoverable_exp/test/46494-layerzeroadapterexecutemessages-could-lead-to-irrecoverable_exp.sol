// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./46494-layerzeroadapterexecutemessages-could-lead-to-irrecoverable.sol";

/*//////////////////////////////////////////////////////////////////////////
    Sweep n Flip — LayerZeroAdapter.executeMessages wrong pop (#46494)
//////////////////////////////////////////////////////////////////////////*/
contract ExecuteMessagesWrongPopTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.bridge().delivered(1), "token 1 delivered");
        assertFalse(e.bridge().delivered(2), "token 2 lost");
        assertTrue(e.adapter().lockedInBridge(2), "token 2 still locked");
        assertEq(e.adapter().getPendingMessagesToExecuteCount(), 0);
    }
}
