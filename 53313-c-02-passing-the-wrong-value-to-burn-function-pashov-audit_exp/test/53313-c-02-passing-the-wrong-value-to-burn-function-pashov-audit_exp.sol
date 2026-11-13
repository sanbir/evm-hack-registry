// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Asset, Exploit, OmoVaultFixed} from "./53313-c-02-passing-the-wrong-value-to-burn-function-pashov-audit.sol";

contract Finding53313Test is Test {
    function test_topOff_burns_bobs_shares() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.aliceGot(), 200 ether, "alice receives her 200");
        assertEq(e.vaultShares(), 0, "both escrows' shares were burned");
        assertEq(e.bobEscrow(), 100 ether, "bob's record still says 100 shares");
        assertEq(e.vaultAssets(), 200 ether, "bob's 200 assets stuck");
        assertTrue(e.bobTopOffReverted(), "bob's topOff reverts");
    }

    function test_control_burns_record_shares() public {
        Asset asset = new Asset();
        OmoVaultFixed vault = new OmoVaultFixed(asset);
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vault.openRedeem(alice, 100 ether);
        vault.openRedeem(bob, 100 ether);
        asset.mint(address(vault), 400 ether);
        vault.topOff(alice);
        assertEq(vault.balanceOf(address(vault)), 100 ether, "bob's shares remain");
        vault.topOff(bob);
        assertEq(asset.balanceOf(alice), 200 ether, "alice 200");
        assertEq(asset.balanceOf(bob), 200 ether, "bob 200");
        assertEq(asset.balanceOf(address(vault)), 0, "vault empty");
        assertEq(vault.balanceOf(address(vault)), 0, "no shares left");
    }
}
