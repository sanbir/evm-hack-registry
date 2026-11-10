// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Holder,
    LiquidityFacetFixed,
    PLP,
    RewardToken
} from "./57736-c-02-plp-transfer-or-balance-updates-do-not-update-reward-in.sol";

contract Finding57736Test is Test {
    function test_transfer_moves_the_100_rwd_to_the_recipient() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fairVictimAmt(), 100 ether, "holder was owed 100");
        assertEq(e.fairAttackerAmt(), 0, "recipient was owed 0");
        assertEq(e.victimReward(), 0, "holder is owed 0 after the transfer");
        assertEq(e.attackerReward(), 100 ether, "recipient is owed 100 after the transfer");
        assertEq(e.stolen(), 100 ether, "claim pays the recipient 100");
        assertEq(e.reward().balanceOf(address(e)), 100 ether, "recipient holds the 100 RWD");
        assertEq(e.reward().balanceOf(address(e.victim())), 0, "holder was paid nothing");
    }

    function test_control_transfer_pays_the_holder() public {
        RewardToken reward = new RewardToken();
        PLP plp = new PLP();
        LiquidityFacetFixed pool = new LiquidityFacetFixed(plp, reward);
        Holder holder = new Holder();
        address recipient = address(0xB0B);

        pool.deposit(address(holder), 100 ether);
        reward.mint(address(pool), 100 ether);
        pool.accrue(pool.Q128());
        pool.transferPLP(address(holder), recipient, 100 ether);

        uint256 toHolder = pool.claim(address(holder));
        uint256 toRecipient = pool.claim(recipient);

        assertEq(toHolder, 100 ether, "control pays the holder 100");
        assertEq(toRecipient, 0, "control pays the recipient 0");
        assertEq(reward.balanceOf(address(holder)), 100 ether, "holder received 100");
        assertEq(reward.balanceOf(recipient), 0, "recipient received 0");
    }
}
