// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, OToken, AFiBaseFixed} from "./37167-potential-asset-under-disbursement-in-withdraw-function-of-a.sol";

contract Finding37167Test is Test {
    function test_exploit_pays_400_of_the_fair_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 400 ether, "paid 400");
        assertEq(e.fair(), 1000 ether, "fair 1000");
        assertEq(e.fair() - e.paid(), 600 ether, "short 600");
        assertEq(e.token().balanceOf(address(e)), 400 ether, "user balance");
        assertEq(e.vault().sharesOf(address(e)), 0, "shares burned");
    }

    function test_control_reverts_when_short_and_pays_1000_when_funded() public {
        OToken token = new OToken();
        AFiBaseFixed vault = new AFiBaseFixed(token);
        token.mint(address(vault), 400 ether);
        vault.deposit(address(this), 1000 ether, 1000 ether);

        vm.expectRevert(bytes("short"));
        vault.withdraw(1000 ether);
        assertEq(vault.sharesOf(address(this)), 1000 ether, "shares kept");
        assertEq(token.balanceOf(address(this)), 0, "nothing paid");

        token.mint(address(vault), 600 ether);
        uint256 paid = vault.withdraw(1000 ether);
        assertEq(paid, 1000 ether, "funded withdraw pays the fair 1000");
        assertEq(token.balanceOf(address(this)), 1000 ether, "user received 1000");
    }
}
