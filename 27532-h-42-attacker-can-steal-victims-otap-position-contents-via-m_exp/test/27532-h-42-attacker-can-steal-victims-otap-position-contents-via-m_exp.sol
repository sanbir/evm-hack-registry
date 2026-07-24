// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27532-h-42-attacker-can-steal-victims-otap-position-contents-via-m.sol";

contract StealOtapTest is Test {
    function test_steal_otap_shares_via_magnetar() public {
        Exploit exp = new Exploit();
        exp.run();
        assertEq(exp.stolen(), exp.SHARES());
    }
}
