// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, OmoVaultFixed, Bob} from "./53329-h-11-pending-withdrawal-tokens-in-redeem-affect-share-price.sol";

contract Finding53329Test is Test {
    function test_exploit_pending_redeem_takes_half_the_yield() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.priceAfterYield(), 1.5 ether, "stale price");
        assertEq(e.aliceAssets(), 150 ether, "alice 150");
        assertEq(e.bobAssets(), 150 ether, "bob 150");
        assertEq(e.asset().balanceOf(address(e)), 150 ether, "alice balance");
        assertEq(e.asset().balanceOf(address(e.bob())), 150 ether, "bob balance");
    }

    function test_control_redeem_locks_the_price() public {
        Asset asset = new Asset();
        OmoVaultFixed vault = new OmoVaultFixed(asset);
        Bob bob = new Bob();
        asset.mint(address(this), 200 ether);
        asset.approve(address(vault), 200 ether);
        vault.deposit(address(this), 100 ether);
        vault.deposit(address(bob), 100 ether);
        vault.redeem(address(this), 100 ether);
        asset.mint(address(this), 100 ether);
        asset.approve(address(vault), 100 ether);
        vault.accrue(100 ether);
        uint256 alice = vault.topOff(address(this));
        uint256 got = bob.withdrawFixed(vault);
        assertEq(alice, 100 ether, "alice locked at 100");
        assertEq(got, 200 ether, "bob keeps the yield");
    }
}
