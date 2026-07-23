// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65528-surplusprocesssurplus-always-reverts-for-managed-collateral.sol";

contract ProcessSurplusManagedDoSTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.processReverts(), "processSurplus reverts");
        assertEq(e.diamondBal(), 0, "diamond empty");
        assertEq(e.surplusStuck(), 8e6, "8e6 stuck on manager");
    }
}
