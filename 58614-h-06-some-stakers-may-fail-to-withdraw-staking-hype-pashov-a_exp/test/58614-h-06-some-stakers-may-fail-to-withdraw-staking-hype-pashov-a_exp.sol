// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58614-h-06-some-stakers-may-fail-to-withdraw-staking-hype-pashov-a.sol";

contract KinetiqBufferWithdrawTest is Test {
    function test_exploit_bufferIgnored_withdrawFails() public {
        Exploit e = new Exploit();
        e.run{value: 100 ether}();

        assertTrue(e.withdrawFailed(), "buggy queue failed");
        assertEq(e.bufferAtFail(), 50 ether, "buffer unused at fail");
        assertEq(e.manager().hypeBuffer(), 10 ether, "fixed path used buffer");
        assertEq(e.manager().pending(address(e.user())), 40 ether);
    }

    receive() external payable {}
}
