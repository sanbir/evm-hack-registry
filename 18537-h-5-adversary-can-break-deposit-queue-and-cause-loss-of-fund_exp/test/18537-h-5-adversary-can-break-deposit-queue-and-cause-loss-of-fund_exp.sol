// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    CarouselFixed,
    User,
    Reverter
} from "./18537-h-5-adversary-can-break-deposit-queue-and-cause-loss-of-fund.sol";

contract Finding18537Test is Test {
    function test_reverting_receiver_sticks_100e18_in_the_queue() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.queuedBefore(), 2, "user then attacker");
        assertTrue(e.queueReverted(), "mintDepositInQueue reverted");
        assertEq(e.queuedAfter(), 2, "nothing was popped");
        assertEq(e.sharesAfter(), 0, "user got no shares");
        assertTrue(e.withdrawReverted(), "withdraw of 100e18 reverted");
        assertEq(e.stuck(), 100 ether, "user's 100e18 is stuck");
        assertEq(e.asset().balanceOf(address(e.user())), 0, "user holds nothing");
        assertEq(e.asset().balanceOf(address(e.vault())), 101 ether, "vault still holds both deposits");
    }

    function test_control_skips_callback_and_user_withdraws_100e18() public {
        Asset asset = new Asset();
        CarouselFixed vault = new CarouselFixed(asset);
        User user = new User();
        Reverter attacker = new Reverter();

        asset.mint(address(user), 100 ether);
        asset.mint(address(attacker), 1 ether);
        user.deposit(vault, asset, 100 ether);
        attacker.deposit(vault, asset, 1 ether);
        assertEq(vault.queueLength(), 2, "same queue");

        vault.mintDepositInQueue(2);

        assertEq(vault.queueLength(), 0, "queue completed");
        assertEq(vault.shares(address(user)), 100 ether, "user was minted 100e18");
        user.pull(vault, 100 ether);
        assertEq(asset.balanceOf(address(user)), 100 ether, "user withdrew 100e18");
        assertEq(vault.shares(address(user)), 0, "shares burned");
    }
}
