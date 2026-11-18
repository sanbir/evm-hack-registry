// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, DepositETH} from
    "./44984-h-04-stale-share-price-usage-leading-to-fund-loss-and-unfair.sol";

contract Finding44984Test is Test {
    function test_exploit_withdrawal_leaves_50_ether_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vault().sharePrice(), 1 ether, "share price still 1:1");
        assertEq(e.paid(), 100 ether, "user paid 100");
        assertEq(e.stuck(), 50 ether, "50 yield stuck");
        assertEq(e.vault().shares(address(e)), 0, "user has no shares left");
        assertEq(e.asset().balanceOf(address(e.vault())), 50 ether, "vault still holds the yield");
    }

    function test_control_refreshed_price_pays_the_yield() public {
        Asset asset = new Asset();
        DepositETH vault = new DepositETH(asset);
        asset.mint(address(this), 150 ether);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(address(this), 100 ether);
        vault.pokeYield(50 ether);
        vault.updateSharePrice();
        assertLt(vault.sharePrice(), 1 ether, "refreshed price is below the stale 1:1");
        // The integer inverse rounds the payout a few wei above 150 ether. Cover that dust.
        asset.mint(address(vault), 1 ether);

        uint256 beforeBal = asset.balanceOf(address(this));
        vault.messageReceivedL2(3, address(this), vault.shares(address(this)));
        uint256 paid = asset.balanceOf(address(this)) - beforeBal;

        assertGt(paid, 150 ether, "user receives the accrued yield");
        assertLt(paid, 151 ether, "only rounding dust above 150");
    }
}
