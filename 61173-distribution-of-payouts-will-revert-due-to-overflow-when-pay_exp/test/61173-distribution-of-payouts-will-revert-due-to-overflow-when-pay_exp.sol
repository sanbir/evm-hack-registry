// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Stable, DividendManagerFixed} from
    "./61173-distribution-of-payouts-will-revert-due-to-overflow-when-pay.sol";

contract Finding61173Test is Test {
    function test_uint64_cast_locks_earlier_payouts() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.reverted(), "claim reverted");
        assertEq(e.token().balanceOf(address(e)), 0, "holder got nothing");
        assertEq(e.token().balanceOf(address(e.manager())), e.stuck(), "full pot stuck");
        assertGt(e.stuck(), type(uint64).max, "50e18 does not fit");
        assertLt(4 * 50e6, type(uint64).max, "the four 6-decimal payouts fit");
    }

    function test_control_uint256_pays_the_pot() public {
        Stable token = new Stable();
        DividendManagerFixed fixedManager = new DividendManagerFixed(token);
        uint256 pot = 4 * 50e6 + 50 ether;
        token.mint(address(fixedManager), pot);
        uint256 got = fixedManager.claim(address(this), pot);
        assertEq(got, pot, "uint256 claim pays everything");
        assertEq(token.balanceOf(address(this)), pot, "holder received the pot");
        assertEq(token.balanceOf(address(fixedManager)), 0, "manager empty");
    }
}
