// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, VaultFixed, IERC20} from "./54895-the-totalft-and-accretingprincipal-are-updated-incorrectly-i.sol";

contract Finding54895Test is Test {
    function test_exploit_second_decrement_locks_the_rest() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstOut(), 50 ether, "first withdraw paid once");
        assertTrue(e.secondReverted(), "rest underflows");
        assertEq(e.locked(), 150 ether, "150 stays in the vault");
        assertEq(e.asset().balanceOf(address(e)), 50 ether, "user only got 50 of 200");
        assertEq(e.vault().totalFt(), 100 ether, "totalFt fell by 100 on a 50 transfer");
    }

    function test_control_single_decrement_returns_the_deposit() public {
        Asset asset = new Asset();
        VaultFixed fixedVault = new VaultFixed(IERC20(address(asset)));
        asset.mint(address(this), 200 ether);
        asset.approve(address(fixedVault), 200 ether);
        fixedVault.deposit(200 ether);

        uint256 got = fixedVault.withdraw(200 ether);

        assertEq(got, 200 ether, "full withdrawal");
        assertEq(asset.balanceOf(address(this)), 200 ether, "user recovered 200");
        assertEq(asset.balanceOf(address(fixedVault)), 0, "vault empty");
        assertEq(fixedVault.totalFt(), 0, "totalFt matches cash");
    }
}
