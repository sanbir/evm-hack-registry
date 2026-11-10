// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LogicFixed,
    Token
} from "./61564-rewards-distributed-with-timeweightedincentivelogic-can-cont.sol";

contract Finding61564Test is Test {
    function test_exploit_late_claim_pays_extra() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimed(), e.LATE(), "late claim is the inflated amount");
        assertEq(e.claimed() - e.FAIR(), e.EXTRA(), "extra above the end-of-window payout");
        assertEq(e.kept(), e.EXTRA(), "staker keeps the extra");
        assertEq(e.reward().balanceOf(address(e)), e.EXTRA());
    }

    function test_control_pays_zero_extra_after_the_end() public {
        Token reward = new Token("Reward", "RWD", 18);
        LogicFixed logic = new LogicFixed(reward);
        logic.stake(100 ether);
        reward.mint(address(this), 1000 ether);
        reward.approve(address(logic), 1000 ether);
        logic.depositRewards(1000 ether, 1 weeks);
        logic.advance(5 weeks);

        uint256 paid = logic.claim();
        assertEq(paid, 499999173280423147200, "capped claim equals the end-of-window amount");
        assertEq(paid - 499999173280423147200, 0, "extra after the end is 0");

        logic.advance(1 weeks);
        uint256 second = logic.claim();
        assertEq(second, 0, "a later claim pays 0");
    }
}
