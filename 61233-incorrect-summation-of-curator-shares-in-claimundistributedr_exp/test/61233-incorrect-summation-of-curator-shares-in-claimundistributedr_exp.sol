// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, VaultTokenized, RewardsFixed} from
    "./61233-incorrect-summation-of-curator-shares-in-claimundistributedr.sol";

contract Finding61233Test is Test {
    function test_exploit_double_counts_curator_and_locks_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.totalShares(), 8000, "8000 bp instead of 7000");
        assertEq(e.distributorPaid(), 2000 ether, "distributor underpaid");
        assertEq(e.locked(), 1000 ether, "1000 locked");
        assertEq(e.token().balanceOf(address(e.rewards())), 1000 ether, "stuck in rewards");
    }

    function test_control_curator_is_counted_once() public {
        Token token = new Token();
        address distributor = address(uint160(0xD157));
        address operator = address(uint160(0x0A0));
        address curator = address(uint160(0xC0A));
        VaultTokenized vault1 = new VaultTokenized(curator);
        VaultTokenized vault2 = new VaultTokenized(curator);
        RewardsFixed rewards = new RewardsFixed(token, distributor, operator, curator, vault1, vault2);
        rewards.seed(3);
        token.mint(address(rewards), 10_000 ether);
        uint256 undistributed = rewards.claimUndistributedRewards(3);
        rewards.claimShare(3, 0, operator);
        rewards.claimShare(3, 1, address(vault1));
        rewards.claimShare(3, 1, address(vault2));
        rewards.claimShare(3, 2, curator);

        assertEq(undistributed, 3000 ether, "fair undistributed");
        assertEq(token.balanceOf(distributor), 3000 ether, "distributor paid");
        assertEq(token.balanceOf(address(rewards)), 0, "nothing locked");
    }
}
