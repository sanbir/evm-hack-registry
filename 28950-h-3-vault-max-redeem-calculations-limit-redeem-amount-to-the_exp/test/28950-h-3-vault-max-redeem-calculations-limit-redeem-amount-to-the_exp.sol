// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./28950-h-3-vault-max-redeem-calculations-limit-redeem-amount-to-the.sol";

contract Finding28950Test is Test {
    function test_max_redeem_is_1_of_2000000() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("deposit", e.DEPOSIT());
        console2.log("cap", e.vault().lastCap());
        console2.log("redeemed", e.redeemed());
        console2.log("stuck", e.stuck());

        assertEq(e.DEPOSIT(), 2_000_000 ether, "deposit");
        assertEq(e.vault().lastCap(), 1 ether, "cap");
        assertEq(e.redeemed(), 1 ether, "redeemed");
        assertLt(e.redeemed(), e.DEPOSIT(), "less than deposit");
        assertEq(e.stuck(), 1_999_999 ether, "stuck");
        assertEq(e.token().balanceOf(address(e.vault())), 1_999_999 ether, "vault");
        assertEq(e.token().balanceOf(address(e)), 1 ether, "user");
    }

    function test_control_fair_redeem_is_1999998() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("fair cap", e.vault().fairCap());
        console2.log("fair redeemed", e.fairRedeemed());

        assertEq(e.vault().fairCap(), 1_999_998 ether, "fair cap");
        assertEq(e.fairRedeemed(), 1_999_998 ether, "fair");
        assertGt(e.fairRedeemed(), 1 ether, "more than the buggy cap");
        assertEq(e.token().balanceOf(address(e)), 1_999_998 ether, "user");
        assertEq(e.token().balanceOf(address(e.vault())), 2 ether, "residual");
    }
}
