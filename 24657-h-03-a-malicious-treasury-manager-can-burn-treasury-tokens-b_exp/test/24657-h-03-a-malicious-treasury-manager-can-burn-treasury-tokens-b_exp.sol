// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./24657-h-03-a-malicious-treasury-manager-can-burn-treasury-tokens-b.sol";

contract NotionalTreasuryFeeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.comp().balanceOf(address(e.wallet())), 0, "treasury COMP drained");
        assertEq(e.weth().balanceOf(address(e.wallet())), 0, "treasury WETH zero");
        assertEq(e.weth().balanceOf(address(e)), 50e18, "manager kept WETH");
        assertEq(e.comp().balanceOf(address(e)), 100e18, "manager got COMP");
    }
}
