// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, Treasury, FeeAuction} from
    "./61536-fee-auction-allows-buying-zero-assets-leading-to-front-runni.sol";

contract Finding61536Test is Test {
    function test_exploit_victim_pays_double_and_receives_nothing() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.asset().balanceOf(address(e)), 1000 ether, "front-run took the basket");
        assertEq(e.asset().balanceOf(address(e.victim())), 0, "victim assets");
        assertEq(e.auction().zeroAssetPaid(), 200 ether, "victim paid 200 for zero assets");
        assertEq(e.pay().balanceOf(address(e.victim())), 0, "victim spent the doubled price");
        assertEq(e.pay().balanceOf(address(e.treasury())), 300 ether, "auction kept both payments");
    }

    function test_control_zero_balance_buy_reverts() public {
        MockToken pay = new MockToken();
        MockToken asset = new MockToken();
        Treasury treasury = new Treasury();
        FeeAuction auction = new FeeAuction(pay, address(treasury), 100 ether);
        asset.mint(address(auction), 1000 ether);
        pay.mint(address(this), 300 ether);
        pay.approve(address(auction), type(uint256).max);

        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        auction.buy(assets, address(this));

        vm.expectRevert(bytes("zero assets"));
        auction.buyFixed(assets, address(this));
        assertEq(pay.balanceOf(address(this)), 200 ether, "second payment was not taken");
        assertEq(asset.balanceOf(address(this)), 1000 ether, "first buyer still holds the basket");
    }
}
