// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Prize,
    WheelFixed
} from "./64739-h-01-stake-manipulation-during-cooldown-period-allows-probab.sol";

contract Finding64739Test is Test {
    function test_exploit_cooldown_stake_wins_the_prize() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.won(), 100 ether, "attacker won N");
        assertEq(e.wheel().winner(), address(e), "winner");
        assertEq(e.wheel().stakeA(), 1001, "stake grew during cooldown");
        assertTrue(e.wheel().cooldown(), "flag set");
    }

    function test_control_freezes_stake_during_cooldown() public {
        Prize prize = new Prize();
        WheelFixed wheel = new WheelFixed(prize, address(this), address(0xBEEF));
        prize.mint(address(wheel), 100 ether);
        wheel.join(address(this), 1);
        wheel.join(address(0xBEEF), 100);

        vm.expectRevert(bytes("frozen"));
        wheel.joinDuringCooldown(1000);

        wheel.spin();
        assertEq(wheel.stakeA(), 1, "stake frozen");
        assertEq(wheel.winner(), address(0xBEEF), "victim wins the same roll");
        assertEq(prize.balanceOf(address(this)), 0, "attacker is not paid");
        assertEq(prize.balanceOf(address(wheel)), 100 ether, "prize stays");
    }
}
