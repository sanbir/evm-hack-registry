// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./13825-getlockedcount-is-iterating-over-all-history-of-delegations.sol";
contract Finding13825Test is Test {
    function test_long_history_blocks_transfer_and_bounded_withdraws() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.vulnerableMoved(), "vuln");
        assertTrue(e.controlMoved(), "control");
        assertEq(e.sinkBalance(), e.N(), "withdrawn");
        console2.log("vulnerable moved");
        console2.log(e.vulnerableMoved() ? 1 : 0);
        console2.log("control withdrawn");
        console2.log(e.sinkBalance());
    }
}
