// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, StakingFixed} from
    "./55484-h-01-stakingearned-calculates-the-rewards-wrongly-pashov-aud.sol";

contract Finding55484Test is Test {
    address internal constant ALICE = 0x1111111111111111111111111111111111111111;

    function test_exploit_deficit_pays_8() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(ALICE), 8 ether, "alice received 8");
        assertEq(e.token().balanceOf(address(e.staking())), 72 ether, "72 left");
    }

    function test_control_deficit_pays_0() public {
        Token token = new Token();
        StakingFixed staking = new StakingFixed(token);
        staking.seed(ALICE, 10 ether, 100 ether, 80 ether);
        assertEq(staking.earned(ALICE), 0, "no reward while underwater");
        assertEq(staking.giveReward(ALICE), 0, "nothing paid");
        assertEq(token.balanceOf(ALICE), 0, "alice received nothing");
        assertEq(token.balanceOf(address(staking)), 80 ether, "80 stays");
    }
}
