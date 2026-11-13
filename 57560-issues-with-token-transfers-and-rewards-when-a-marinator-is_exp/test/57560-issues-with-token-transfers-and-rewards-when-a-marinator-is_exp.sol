// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MarinateV2Fixed,
    Marinator,
    MiniToken
} from "./57560-issues-with-token-transfers-and-rewards-when-a-marinator-is.sol";

contract Finding57560Test is Test {
    function test_exploit_delist_then_transfer_strands_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.multipliedAfter(), 300 ether, "multiplied stake inflated");
        assertEq(e.supplyAfter(), 200 ether, "supply");
        assertEq(e.aRewardsAfterRelist(), 0, "A cannot collect after relist");
        assertEq(e.stuck(), 100 ether, "100 rewards stuck");
        assertEq(e.reward().balanceOf(address(e.b())), 100 ether, "B was paid");
    }

    function test_control_removal_pays_and_transfer_requires_both_whitelisted() public {
        MiniToken umami = new MiniToken("UMAMI", "UMAMI");
        MiniToken reward = new MiniToken("Reward", "RWD");
        MarinateV2Fixed marinate = new MarinateV2Fixed(umami, reward);
        Marinator a = new Marinator();
        Marinator b = new Marinator();
        marinate.addToContractWhitelist(address(a));
        marinate.addToContractWhitelist(address(b));
        umami.mint(address(a), 100 ether);
        umami.mint(address(b), 100 ether);
        a.approveAll(umami, address(marinate));
        b.approveAll(umami, address(marinate));
        a.stakeFixed(marinate, 100 ether);
        b.stakeFixed(marinate, 100 ether);
        reward.mint(address(this), 200 ether);
        reward.approve(address(marinate), type(uint256).max);
        marinate.addReward(200 ether);
        marinate.removeFromContractWhitelist(address(a));
        assertEq(reward.balanceOf(address(a)), 100 ether, "A paid on removal");
        vm.expectRevert(bytes("wl"));
        a.xferFixed(marinate, address(b), 100 ether);
        b.withdrawFixed(marinate);
        assertEq(reward.balanceOf(address(b)), 100 ether, "B paid");
        assertEq(reward.balanceOf(address(marinate)), 0, "nothing stuck");
    }
}
