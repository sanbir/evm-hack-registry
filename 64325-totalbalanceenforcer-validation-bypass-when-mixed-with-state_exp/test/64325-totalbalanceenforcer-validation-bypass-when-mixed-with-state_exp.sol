// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64325-totalbalanceenforcer-validation-bypass-when-mixed-with-state.sol";

contract TotalBalanceBypassTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run{value: 10 ether}();

        assertTrue(e.alice().executed(), "bypassed and executed");
        assertEq(address(e.bob()).balance, 3 ether, "bob paid 3 ETH");
        assertEq(address(e.alice()).balance, 10 ether - 3.3 ether, "alice lost 3.3");
    }
}
