// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    ElyVaultFixed,
    Exploit
} from "./63545-h-02-elyasset-price-calculation-errors-cause-underflow-rever.sol";

contract Finding63545Test is Test {
    function test_exploit_price_underflow_leaves_funds_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.reverted(), "redeem reverted");
        assertEq(e.stuck(), 1050 ether, "1050 stays stuck");
        assertEq(e.received(), 0, "holder received nothing");
        assertEq(e.vault().shares(address(e)), 1000 ether, "shares not burned");
    }

    function test_control_price_pays_1045() public {
        Asset asset = new Asset();
        ElyVaultFixed vault = new ElyVaultFixed(asset);
        asset.mint(address(vault), 1050 ether);
        vault.mintShares(address(this), 1000 ether);

        uint256 payout = vault.redeem(address(this));

        assertEq(vault.price(), 1.045 ether, "fair price");
        assertEq(payout, 1045 ether, "control pays 1045");
        assertEq(asset.balanceOf(address(this)), 1045 ether, "holder");
        assertEq(asset.balanceOf(address(vault)), 5 ether, "fee remains");
    }
}
