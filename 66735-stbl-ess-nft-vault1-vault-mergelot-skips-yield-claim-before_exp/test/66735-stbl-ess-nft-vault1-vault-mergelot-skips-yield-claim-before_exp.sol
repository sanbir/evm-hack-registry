// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Reward, YLD, YieldDistributor, Issuer, SplitMerge, VaultFixed} from
    "./66735-stbl-ess-nft-vault1-vault-mergelot-skips-yield-claim-before.sol";

contract Finding66735Test is Test {
    function test_exploit_merge_strands_40_reward_on_the_burned_nft() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stranded(), 40 ether, "40 still earned");
        assertEq(e.reward().balanceOf(address(e.dist())), 40 ether, "distributor holds it");
        assertEq(e.reward().balanceOf(address(e)), 0, "owner received nothing");
        assertEq(e.dist().earned(e.mergedId()), 0, "merged nft did not inherit it");
        assertTrue(e.yld().disabled(e.NFT_A()), "burned");
    }

    function test_control_claim_before_merge_pays_the_40() public {
        Reward reward = new Reward();
        YLD yld = new YLD();
        YieldDistributor dist = new YieldDistributor(reward, yld);
        Issuer issuer = new Issuer(dist);
        SplitMerge splitMerge = new SplitMerge(yld, issuer);
        VaultFixed vault = new VaultFixed(splitMerge, dist);
        reward.mint(address(this), 40 ether);
        reward.approve(address(dist), 40 ether);
        dist.distribute(11, 40 ether);

        uint256 merged = vault.mergeLot(11, 12);
        assertEq(reward.balanceOf(address(vault)), 40 ether, "claimed before burn");
        assertEq(reward.balanceOf(address(dist)), 0, "distributor empty");
        assertEq(dist.earned(11), 0, "old earned cleared");
        assertEq(dist.earned(merged), 0, "new nft starts clean");
        assertTrue(yld.disabled(11), "burned after the claim");
    }
}
