// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62850-h-03-users-escape-paying-tx-gas.sol";

contract PoC_62850 is Test {
    function test_user_withdraws_before_async_gas_repayment() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.escaped(), 100);
        assertEq(exploit.outstanding(), 80);
        assertEq(exploit.gasTank().balances(address(exploit)), 0);
    }
}
