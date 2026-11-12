// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Vault} from "./58101-h-04-withdraw-worst-price-will-distort-shareprice-pashov-aud.sol";

contract Finding58101Test is Test {
    function test_exploit_next_depositor_minted_wrong_shares() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.distortedPrice(), 140, "share price 140 = 35/3, not the fair 135 = 11.25");
        assertEq(e.fairPrice(), 135, "control price is assets/supply");
        assertEq(e.wrongShares(), 2_700, "depositor minted 2700");
        assertEq(e.fairShares(), 2_800, "fair mint is 2800");
        assertEq(e.vault().balanceOf(address(this)), 2_700, "caller received the short mint");
        assertEq(e.fixedVault().balanceOf(address(e)), 2_800, "control receiver got the fair mint");
    }

    function test_control_fair_price_mints_more_shares() public {
        Exploit e = new Exploit();
        e.run();
        assertGt(e.fairShares(), e.wrongShares(), "fair price mints more shares for the same assets");
        assertEq(e.fairShares() - e.wrongShares(), 100, "shortfall is 100 shares");
    }
}
