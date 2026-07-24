// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26048-h-14-user-may-underpay-for-the-remote-call-executiongas-on-t.sol";

contract MaiaUnderpayExecGasTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_underpay_drains_shared_budget() public {
        exp.run{value: 2 ether}();
        emit log_named_uint("deposited", exp.depositedByAgent());
        emit log_named_uint("charged", exp.chargedByAnycall());
        emit log_named_uint("stolen premium gap", exp.stolenFromShared());
        assertGt(exp.chargedByAnycall(), exp.depositedByAgent());
        assertEq(exp.stolenFromShared(), 150_000 * 10 gwei);
        assertLt(exp.sharedBudgetEnd(), exp.sharedBudgetStart());
    }
}
