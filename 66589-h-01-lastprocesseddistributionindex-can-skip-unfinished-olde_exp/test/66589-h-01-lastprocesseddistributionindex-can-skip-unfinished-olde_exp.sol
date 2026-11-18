// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, RewardStreamFixed} from
    "./66589-h-01-lastprocesseddistributionindex-can-skip-unfinished-olde.sol";

contract Finding66589Test is Test {
    function test_exploit_cursor_skips_unfinished_distribution() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 200 ether, "only the vested slice was paid");
        assertEq(e.locked(), 300 ether, "300 left in the stream");
        assertEq(e.token().balanceOf(address(e.stream())), 300 ether, "stream still holds 300");
        assertEq(e.stream().lastProcessedDistributionIndex(address(e)), 2, "cursor passed D0");
        assertEq(e.stream().stranded(address(e)), 300 ether, "D0 remainder is behind the cursor");
        assertEq(e.stream().claimable(address(e)), 0, "claim scan cannot see D0");
        assertEq(e.stream().epochsClaimed(address(e), 0), 1, "only epoch 1 of 4 was recorded");
    }

    function test_control_cursor_stops_at_unfinished_prefix() public {
        Token token = new Token();
        RewardStreamFixed stream = new RewardStreamFixed(token);
        token.mint(address(stream), 500 ether);
        stream.addDistribution(4, 0, 400 ether);
        stream.addDistribution(1, 0, 100 ether);

        uint256 paid = stream.updateReward(address(this));
        assertEq(paid, 200 ether, "same vested slice");
        assertEq(stream.lastProcessedDistributionIndex(address(this)), 0, "cursor stays on D0");
        assertEq(stream.epochsClaimed(address(this), 0), 1, "D0 still in front of the cursor");
        assertEq(stream.stranded(address(this)), 0, "nothing is behind the cursor");
        assertEq(token.balanceOf(address(stream)), 300 ether, "unvested 300 remains reachable");
        assertEq(token.balanceOf(address(this)), 200 ether, "caller received the vested 200");
    }
}
