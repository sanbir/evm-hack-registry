// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, VaultFixed} from "./61528-inconsistent-balance-tracking-in-vault-creates-dos-for-asset.sol";

contract Finding61528Test is Test {
    function test_exploit_borrow_reverts_after_burn() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.borrowOpened(), false, "borrow reverted");
        assertEq(e.suppliesAfter(), 85 ether, "supply 85");
        assertEq(e.borrowsAfter(), 90 ether, "borrows 90");
    }

    function test_control_burn_checks_idle_balance() public {
        Token asset = new Token("ASSET");
        VaultFixed vault = new VaultFixed(asset);
        asset.mint(address(this), 105 ether);
        asset.approve(address(vault), 100 ether);
        vault.mint(100 ether);
        vault.borrow(address(0xB0B), 90 ether);
        vm.expectRevert(bytes("idle"));
        vault.burn(address(this), 15 ether);
        vault.borrow(address(0xB0B), 1 ether);
        assertEq(vault.totalSupplies(), 100 ether, "supply unchanged");
        assertEq(vault.totalBorrows(), 91 ether, "borrow still opens");
    }
}
