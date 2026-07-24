// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./58393-lend-cross-chain-repayment-updates-the-wrong-borrow-balance.sol";

contract Finding58393Test is Test {
    function testFinding58393() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("before", e.beforeValue());
        emit log_named_uint("after", e.afterValue());
        emit log_named_uint("delta", e.profit());
        assertTrue(e.stateDiverged());
        assertGt(e.profit(), 0);
        
    }
}
