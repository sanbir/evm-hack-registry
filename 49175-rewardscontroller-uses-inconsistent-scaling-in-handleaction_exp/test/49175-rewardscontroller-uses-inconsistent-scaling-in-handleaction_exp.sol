// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    ATokenErc6909,
    AwethFixed,
    AwethToken,
    Exploit,
    RewardsControllerFixed
} from "./49175-rewardscontroller-uses-inconsistent-scaling-in-handleaction.sol";

contract Finding49175Test is Test {
    function test_exploit_withdraw_reverts_and_deposit_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.withdrew(), "withdraw did not complete");
        assertEq(e.stuck(), 100 ether, "100e18 stuck in the market");
        assertEq(e.token().balanceOf(address(e.market())), 100 ether, "market balance");
        assertEq(e.token().balanceOf(address(e)), 0, "caller balance");
        assertEq(e.mini().scaledTotalSupply(1), 95.2 ether, "scaled supply");
    }

    function test_control_one_scale_and_withdraw_pays() public {
        AwethToken token = new AwethToken();
        ATokenErc6909 mini = new ATokenErc6909();
        RewardsControllerFixed rewards = new RewardsControllerFixed();
        AwethFixed market = new AwethFixed(address(token));
        rewards.markMini(address(mini));
        market.wire(rewards, address(mini));
        token.mint(address(market), 100 ether);

        market.withdraw();

        assertEq(rewards.lastDiff(), 5 ether, "105e18 - 100e18");
        assertEq(token.balanceOf(address(this)), 100 ether, "withdraw paid 100e18");
        assertEq(token.balanceOf(address(market)), 0, "market emptied");
    }
}
