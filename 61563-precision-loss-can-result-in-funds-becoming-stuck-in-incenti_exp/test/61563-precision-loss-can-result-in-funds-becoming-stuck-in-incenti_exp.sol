// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    LogicFixed,
    Token
} from "./61563-precision-loss-can-result-in-funds-becoming-stuck-in-incenti.sol";

contract Finding61563Test is Test {
    function test_exploit_remainder_stuck_after_full_claim() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), e.PAID(), "staker receives only the floored stream");
        assertLt(e.paid(), e.AMOUNT(), "claim is less than funded");
        assertEq(e.stuck(), e.STUCK(), "5187955 base units stay in the logic");
        assertEq(e.reward().balanceOf(address(e.logic())), 5_187_955);
    }

    function test_control_final_claim_pays_the_remainder() public {
        Token reward = new Token("Wrapped BTC", "WBTC", 8);
        LogicFixed logic = new LogicFixed(reward);
        logic.stake(1 ether);
        reward.mint(address(this), 11_235_955);
        reward.approve(address(logic), 11_235_955);
        logic.depositRewards(11_235_955, 10 weeks);
        logic.advance(10 weeks);

        uint256 paid = logic.claim();
        assertEq(paid, 11_235_955, "control pays the full deposit");
        assertEq(reward.balanceOf(address(logic)), 0, "nothing stuck");
        assertEq(reward.balanceOf(address(this)), 11_235_955, "staker received every unit");
    }
}
