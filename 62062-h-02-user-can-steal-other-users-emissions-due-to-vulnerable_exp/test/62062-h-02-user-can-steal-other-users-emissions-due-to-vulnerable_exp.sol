// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62062-h-02-user-can-steal-other-users-emissions-due-to-vulnerable.sol";

contract BlendEmissionsStealTest is Test {
    function test_exploit_claimWithoutUpdateStealsEmissions() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 200 ether, "inflated steal");
        assertTrue(e.victimClaimFailed(), "victim cannot claim");
        assertEq(e.token().balanceOf(address(e)), 200 ether, "attacker holds stolen");
    }
}
