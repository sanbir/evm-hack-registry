// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usdc, Wallet, FlashDuels} from
    "./45830-user-controlled-options-price-zokyo-none-filament-markdown.sol";

contract Finding45830Test is Test {
    function test_exploit_one_usdc_takes_the_wager_pool() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.usdc().balanceOf(address(e.attacker())), 999_999_999, "attacker payout");
        assertEq(e.usdc().balanceOf(address(e.honest())), 999_999, "honest payout");
        assertEq(e.usdc().balanceOf(address(e.attacker())) - 1_000_000, 998_999_999, "net profit");
    }

    function test_control_min_price_rejects_one_wei() public {
        Usdc usdc = new Usdc();
        Wallet attacker = new Wallet();
        FlashDuels duels = new FlashDuels(usdc, 1_000_000);
        usdc.mint(address(attacker), 1_000_000);
        attacker.approve(usdc, address(duels), 1_000_000);

        vm.expectRevert(bytes("min price"));
        attacker.join(duels, 1, 1_000_000);
        assertEq(usdc.balanceOf(address(duels)), 0, "nothing deposited");
    }
}
