// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    ZeroLendAToken
} from "./40817-zlrewardscontroller-contract-is-incompatible-with-zerolend-s.sol";

/// The hook ZeroLend aTokens actually call. Accrues the caller's share, then claim pays it.
contract ZLRewardsControllerFixed {
    RewardToken public reward;
    mapping(address => uint256) public accrued;

    constructor(RewardToken _reward) {
        reward = _reward;
    }

    function depositRewards(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function handleAction(address user, uint256 totalSupply_, uint256 userBalance) external {
        if (totalSupply_ == 0 || userBalance == 0) return;
        uint256 share = reward.balanceOf(address(this)) * userBalance / totalSupply_;
        if (share > accrued[user]) accrued[user] = share;
    }

    function claim(address user) external returns (uint256 paid) {
        paid = accrued[user];
        if (paid != 0) {
            accrued[user] = 0;
            reward.transfer(user, paid);
        }
    }
}

contract Finding40817Test is Test {
    function test_exploit_claim_pays_0_while_1000_sits_in_the_controller() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.hookReverted(), "aToken handleAction reverted");
        assertEq(e.claimed(), 0, "claim paid 0");
        assertEq(e.controllerBalance(), e.REWARD(), "1000 ZERO stuck in the controller");
        assertEq(e.userRewardBalance(), 0, "user received 0 ZERO");
        assertEq(e.aToken().balanceOf(address(e)), e.SUPPLY(), "aToken balance unchanged");
        assertEq(e.REWARD(), 1000e18, "harm magnitude");
    }

    function test_control_handleAction_lets_the_holder_claim_1000() public {
        RewardToken reward = new RewardToken();
        ZLRewardsControllerFixed controller = new ZLRewardsControllerFixed(reward);
        ZeroLendAToken aToken = new ZeroLendAToken(address(controller));
        aToken.seed(address(this), 100e18);
        reward.mint(address(this), 1000e18);
        reward.approve(address(controller), 1000e18);
        controller.depositRewards(1000e18);

        // The same transfer now hits handleAction and accrues the full 1,000 ZERO.
        aToken.transfer(address(0xBEEF), 1);
        uint256 paid = controller.claim(address(this));

        assertEq(paid, 1000e18, "claim pays 1000");
        assertEq(reward.balanceOf(address(this)), 1000e18, "holder received 1000 ZERO");
        assertEq(reward.balanceOf(address(controller)), 0, "controller paid out");
    }
}
