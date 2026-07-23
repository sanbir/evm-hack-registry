// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63223-users-can-get-their-withdrawal-active-requests-dosed-by-mali.sol";

contract StrataWithdrawDoSTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
