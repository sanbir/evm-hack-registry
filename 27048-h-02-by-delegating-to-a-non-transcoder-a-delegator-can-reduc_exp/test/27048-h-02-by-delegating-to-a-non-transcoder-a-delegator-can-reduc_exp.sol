// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27048-h-02-by-delegating-to-a-non-transcoder-a-delegator-can-reduc.sol";

/*//////////////////////////////////////////////////////////////
    Livepeer — [H-02] Non-transcoder vote override. Finding 27048
    (Code4rena 2023-08, reporter Banditx0x) — HIGH
//////////////////////////////////////////////////////////////*/
contract LivepeerNonTranscoderOverrideTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_control_transcoder_override_is_fair() public {
        // Control: when Alice IS a transcoder, Bob's override correctly moves
        // only the weight Alice already counted via delegatedAmount.
        BondingVotesGovernor g = new BondingVotesGovernor();
        address aliceT = address(0xA11CE);
        address bobT = address(0xB0B);
        g.bond(aliceT, 100, aliceT); // transcoder
        g.bond(bobT, 1000, aliceT); // delegates to Alice
        // Alice getVotes = delegatedAmount = 1100
        g.castVote(1, aliceT, VoteType.For);
        (, uint256 for1,) = g.tallies(1);
        assertEq(for1, 1100, "transcoder votes full delegatedAmount");
        g.castVote(1, bobT, VoteType.Against);
        (uint256 against2, uint256 for2,) = g.tallies(1);
        // Bob moves his 1000 off For onto Against: For=100, Against=1000
        assertEq(for2, 100, "fair override leaves alice self-stake");
        assertEq(against2, 1000, "bob against");
    }

    function test_non_transcoder_override_cancels_ungranted_weight() public {
        exp.run();
        emit log_named_uint("for after alice", exp.forAfterAlice());
        emit log_named_uint("for after bob", exp.forAfterBob());
        emit log_named_uint("against after bob", exp.againstAfterBob());

        assertEq(exp.forAfterAlice(), 5100, "For before bob");
        assertEq(exp.forAfterBob(), 4100, "For wrongly reduced by 1000");
        assertEq(exp.againstAfterBob(), 1000, "Against = bob");
    }
}
