// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RewardToken} from "./58013-h-02-loss-of-claimable-rewards-upon-gauge-deactivation-pasho.sol";

/// On deactivation, pay the accrued claimable to the staker instead of deleting it.
contract VoterFixed {
    RewardToken public token;
    address public emergencyCouncil;
    uint256 public index;
    uint256 public totalWeight;
    mapping(address => bool) public isAlive;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public supplyIndex;
    mapping(address => uint256) public weights;

    constructor(address _token) {
        token = RewardToken(_token);
        emergencyCouncil = msg.sender;
    }

    function addGauge(address gauge, uint256 weight) external {
        isAlive[gauge] = true;
        weights[gauge] = weight;
        totalWeight += weight;
    }

    function notifyRewardAmount(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        index += (amount * 1e18) / totalWeight;
    }

    function updateFor(address gauge) external {
        uint256 delta = index - supplyIndex[gauge];
        supplyIndex[gauge] = index;
        if (delta > 0 && isAlive[gauge]) {
            claimable[gauge] += (weights[gauge] * delta) / 1e18;
        }
    }

    function killGauge(address gauge, address staker) external returns (uint256 owed) {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(isAlive[gauge], "gauge already dead");
        isAlive[gauge] = false;
        owed = claimable[gauge];
        claimable[gauge] = 0;
        if (owed > 0) token.transfer(staker, owed);
    }
}

contract Finding58013Test is Test {
    function test_exploit_kill_gauge_makes_1000_rewards_unclaimable() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimableBefore(), 1000e18, "1000 was claimable");
        assertEq(e.claimableAfter(), 0, "claimable was zeroed");
        assertEq(e.paid(), 0, "claim pays 0");
        assertEq(e.token().balanceOf(e.STAKER()), 0, "staker received nothing");
        assertEq(e.stuck(), 1000e18, "1000 sits in the voter");
        assertEq(e.voter().claimable(address(e.gauge())), 0, "revive did not restore it");
        assertTrue(e.voter().isAlive(address(e.gauge())), "gauge was revived");
    }

    function test_control_deactivation_pays_the_claimable_rewards() public {
        RewardToken token = new RewardToken();
        VoterFixed voter = new VoterFixed(address(token));
        address gauge = address(0xA11CE);
        address staker = address(0xBEEF);

        token.mint(address(this), 1000e18);
        token.approve(address(voter), 1000e18);
        voter.addGauge(gauge, 1000e18);
        voter.notifyRewardAmount(1000e18);
        voter.updateFor(gauge);
        assertEq(voter.claimable(gauge), 1000e18, "accrued before kill");

        uint256 paid = voter.killGauge(gauge, staker);
        assertEq(paid, 1000e18, "deactivation pays the claimable");
        assertEq(token.balanceOf(staker), 1000e18, "staker received 1000");
        assertEq(token.balanceOf(address(voter)), 0, "nothing left stuck");
        assertEq(voter.claimable(gauge), 0, "accounting cleared after payment");
        assertFalse(voter.isAlive(gauge), "gauge is deactivated");
    }
}
