// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./65649-fluid-processnormalsupplyaction-permits-an-uncapped-withdrawal.sol";

contract Finding65649Test is Test {
    function testFinding65649() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("before", e.beforeValue());
        emit log_named_uint("after", e.afterValue());
        emit log_named_uint("delta", e.profit());
        assertTrue(e.stateDiverged());
        assertGt(e.profit(), 0);
        
    }
}
