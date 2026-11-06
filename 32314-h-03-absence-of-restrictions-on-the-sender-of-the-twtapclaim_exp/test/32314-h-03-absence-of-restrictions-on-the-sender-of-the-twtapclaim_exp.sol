// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RewardToken} from "./32314-h-03-absence-of-restrictions-on-the-sender-of-the-twtapclaim.sol";

/// Warden's restriction, tightened to the position owner. The sponsor noted that
/// checking only "approved" still lets TapTokenReceiver through, because there
/// msg.sender == _to. Only the token holder may claim.
contract TwTAPFixed {
    error NotApproved(uint256 tokenId, address caller);

    RewardToken public reward;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public rewardOf;
    mapping(uint256 => uint256) public claimed;

    constructor(address _reward) {
        reward = RewardToken(_reward);
    }

    function seed(uint256 tokenId, address owner, uint256 amt) external {
        ownerOf[tokenId] = owner;
        rewardOf[tokenId] = amt;
    }

    function claimRewards(uint256 tokenId, address to) external returns (uint256 amount) {
        if (msg.sender != ownerOf[tokenId]) revert NotApproved(tokenId, msg.sender);
        if (to != ownerOf[tokenId]) revert NotApproved(tokenId, msg.sender);
        amount = rewardOf[tokenId] - claimed[tokenId];
        if (amount != 0) {
            claimed[tokenId] += amount;
            reward.transfer(to, amount);
        }
    }
}

contract Finding32314Test is Test {
    function test_exploit_attacker_takes_victim_twtap_rewards() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerBalance(), e.REWARD(), "attacker received the TAP");
        assertEq(e.reward().balanceOf(address(e)), e.REWARD(), "exploit holds the stolen TAP");
        assertEq(e.victimClaim(), 0, "victim claim is 0");
        assertEq(e.reward().balanceOf(e.VICTIM()), 0, "victim received nothing");
        assertEq(e.reward().balanceOf(address(e.twTap())), 0, "twTAP escrow empty");
    }

    function test_control_only_owner_can_claim() public {
        RewardToken reward = new RewardToken();
        TwTAPFixed fixedTw = new TwTAPFixed(address(reward));
        reward.mint(address(fixedTw), 1000e18);
        address victim = address(0xBEEF);
        fixedTw.seed(1, victim, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(TwTAPFixed.NotApproved.selector, uint256(1), address(this)));
        fixedTw.claimRewards(1, address(this));

        vm.prank(victim);
        uint256 amount = fixedTw.claimRewards(1, victim);
        assertEq(amount, 1000e18, "owner claim pays the reward");
        assertEq(reward.balanceOf(victim), 1000e18, "victim received the TAP");
        assertEq(reward.balanceOf(address(this)), 0, "attacker received nothing");
        assertEq(reward.balanceOf(address(fixedTw)), 0, "nothing left escrowed");
    }
}
