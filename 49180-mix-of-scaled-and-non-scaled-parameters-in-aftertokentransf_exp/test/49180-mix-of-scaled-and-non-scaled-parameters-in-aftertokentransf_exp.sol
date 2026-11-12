// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FixedAToken, Incentives, RewardToken} from "./49180-mix-of-scaled-and-non-scaled-parameters-in-aftertokentransf.sol";

contract ScaledMixTest is Test {
    address internal constant BOB = 0x0000000000000000000000000000000000000B0b;
    uint256 internal constant SHARES = 1000 ether;
    uint256 internal constant MOVE = 400 ether;

    function test_exploit_transferPaysTheMixedBalance() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.buggyTo(), MOVE, "mixed recipient prior");
        assertEq(e.buggyFrom(), 1600 ether, "mixed sender prior");
        assertEq(e.fairTo(), 0, "fair recipient prior");
        assertEq(e.bobReward(), MOVE, "bob reward");
        assertEq(e.controlTo(), 0, "control recipient");
        assertEq(e.controlFrom(), SHARES, "control sender");
        assertEq(e.reward().balanceOf(BOB), MOVE, "bob balance");
    }

    function test_control_oneScalePaysNothingToTheNewRecipient() public {
        RewardToken reward = new RewardToken();
        Incentives incentives = new Incentives(address(reward));
        FixedAToken token = new FixedAToken(address(incentives));
        token.dealShares(address(this), SHARES);

        token.transfer(BOB, 1, MOVE);

        assertEq(token.reportedTo(), 0, "prior scaled balance");
        assertEq(token.reportedFrom(), SHARES, "sender scaled balance");
        assertEq(reward.balanceOf(BOB), 0, "bob was paid");
        assertEq(reward.balanceOf(address(this)), SHARES, "sender reward");
    }
}
