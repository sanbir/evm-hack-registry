// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45671-users-would-lose-rewards-if-a-huge-majority-bets-on-the-winn.sol";

contract Finding45671Test is Test {
    function test_exploit_rate_zero_pays_winner_99_and_locks_the_pot() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.treasury().lastRate(), 0);
        assertEq(e.treasury().lastPayout(), 99_000_000 ether);
        assertEq(e.token().balanceOf(address(e.winner())), 99_000_000 ether);
        assertEq(e.token().balanceOf(address(e.treasury())), 1_000_100 ether);
    }

    function test_control_extra_precision_rate_is_nonzero() public {
        Exploit e = new Exploit();
        uint256 rate = e.treasury().calculateUpDownRateFixed(100, 100_000_000, 100);
        assertGt(rate, 0, "scaled rate");
    }
}
