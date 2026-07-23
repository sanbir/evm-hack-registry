// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55052-referencing-the-gateway-balance-in-lockingcontrollerincrease.sol";

contract GatewayDosTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
