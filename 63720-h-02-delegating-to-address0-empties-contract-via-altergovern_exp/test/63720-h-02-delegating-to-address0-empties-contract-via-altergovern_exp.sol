// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63720-h-02-delegating-to-address0-empties-contract-via-altergovern.sol";

contract BobDelegateZeroDrainTest is Test {
    function test_delegate_zero_drains_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.drained(), 2e18, "drained 2 ether accounting");
        assertEq(e.contractBalanceAfter(), 999e18, "999 rewards left");
    }
}
