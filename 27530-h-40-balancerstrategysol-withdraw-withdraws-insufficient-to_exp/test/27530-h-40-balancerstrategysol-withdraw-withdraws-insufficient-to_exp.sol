// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27530-h-40-balancerstrategysol-withdraw-withdraws-insufficient-to.sol";

contract BalancerWithdrawTest is Test {
    function test_withdraw_reverts_insufficient() public {
        Exploit exp = new Exploit();
        exp.run();
        assertTrue(exp.withdrawReverted());
    }
}
