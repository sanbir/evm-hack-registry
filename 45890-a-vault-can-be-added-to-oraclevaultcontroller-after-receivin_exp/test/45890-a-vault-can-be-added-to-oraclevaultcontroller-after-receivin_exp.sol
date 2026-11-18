// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45890-a-vault-can-be-added-to-oraclevaultcontroller-after-receivin.sol";
contract Finding45890Test is Test {
    function test_late_addVault_mints_extra_shares() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.asset().balanceOf(address(e));
        e.run();
        assertEq(beforeBal, 100e18);
        assertEq(e.received(), 150e18);
        assertEq(e.asset().balanceOf(address(e)), 150e18);
        assertEq(e.oracle().prices(address(e.vault())), 1e18);
    }
}
