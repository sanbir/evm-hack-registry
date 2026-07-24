// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30089-h-02-artpiecetotalvotessupply-and-artpiecequorumvotes-are-in.sol";

/*//////////////////////////////////////////////////////////////
    Revolution — inflated art-piece quorum via auction NFT (#30089)
//////////////////////////////////////////////////////////////*/
contract ArtPieceQuorumTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        uint256 pieceId = 1;
        (, uint256 tvs, uint256 quorum, uint256 votesFor, ) = e.index().pieces(pieceId);
        assertEq(tvs, 1100e18, "inflated totalVotesSupply");
        assertEq(quorum, 550e18, "inflated quorum 55% of accessible");
        assertEq(votesFor, 500e18, "honest 50% of accessible cast");
        assertFalse(e.index().hasReachedQuorum(pieceId), "fails inflated quorum");
        assertEq(e.index().accessibleVoteSupply(e.auctionHouse()), 1000e18);
    }
}
