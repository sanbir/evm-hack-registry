// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Credit,
    Exploit,
    ShopFixed
} from "./64703-h-01-it-is-possible-to-purchase-in-game-items-without-signin.sol";

contract Finding64703Test is Test {
    function test_exploit_purchase_without_signup_mints_credit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.credited(), 100 ether, "100 credit for 0");
        assertEq(e.items(), 1, "item recorded");
        assertFalse(e.shop().hasSignedUp(address(e)), "never signed up");
    }

    function test_control_requires_signup() public {
        Credit credit = new Credit();
        ShopFixed shop = new ShopFixed(credit);

        vm.expectRevert(bytes("signup"));
        shop.purchaseShopItem(1);
        assertEq(credit.balanceOf(address(this)), 0, "no credit");

        shop.signUp();
        shop.purchaseShopItem(1);
        assertEq(credit.balanceOf(address(this)), 100 ether, "signed-up caller is paid");
        assertEq(shop.userShopItemPurchases(address(this), 1), 1, "item");
    }
}
