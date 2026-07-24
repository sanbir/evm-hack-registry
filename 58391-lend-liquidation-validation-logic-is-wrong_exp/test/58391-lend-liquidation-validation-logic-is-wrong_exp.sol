// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./58391-lend-liquidation-validation-logic-is-wrong.sol";

contract Finding58391Test is Test {
    function testFinding58391() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("before", e.beforeValue());
        emit log_named_uint("after", e.afterValue());
        emit log_named_uint("delta", e.profit());
        assertTrue(e.stateDiverged());
        assertGt(e.profit(), 0);
        
    }
}
