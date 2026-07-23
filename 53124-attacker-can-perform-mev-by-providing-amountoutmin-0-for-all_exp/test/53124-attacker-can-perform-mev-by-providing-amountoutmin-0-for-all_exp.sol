// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./53124-attacker-can-perform-mev-by-providing-amountoutmin-0-for-all.sol";

contract PermitMevTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
