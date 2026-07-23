// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./55053-stakedtoken-holders-can-circumvent-restriction-by-approving.sol";

contract RestrictionBypassTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.aliceAssetsAfter(), 1000e18, "alice received underlying via proxy");
        assertTrue(e.aliceDirectWithdrawReverted(), "direct withdraw blocked");
    }
}
