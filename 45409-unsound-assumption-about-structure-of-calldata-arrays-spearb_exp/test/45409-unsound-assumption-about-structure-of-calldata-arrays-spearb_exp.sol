// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, PayToken, Vault} from "./45409-unsound-assumption-about-structure-of-calldata-arrays-spearb.sol";

contract Finding45409Test is Test {
    function test_exploit_crafted_pointer_moves_1000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.taken(), 1000 ether, "paid 1000");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "1000 moved");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault emptied");
    }

    function test_control_rejects_the_crafted_pointer() public {
        PayToken token = new PayToken();
        Vault vault = new Vault(token);
        token.mint(address(vault), 1000 ether);

        vm.expectRevert(bytes("crafted"));
        vault.claimFixed(1000 ether, address(this));
        assertEq(token.balanceOf(address(vault)), 1000 ether, "nothing moved");
        assertEq(token.balanceOf(address(this)), 0, "caller received 0");
    }
}
