// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Stake, Treasury, OneVsOneExactPriceFixed} from
    "./45675-the-opponent-has-a-higher-probability-of-winning-than-the-in.sol";

contract Finding45675Test is Test {
    function test_exploit_tie_pays_the_opponent() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.opponentBalance(), 20 ether, "opponent took both stakes");
        assertEq(e.initiatorBalance(), 0, "initiator lost 10");
    }

    function test_control_tie_refunds_both_players() public {
        Stake stake = new Stake();
        Treasury treasury = new Treasury(stake);
        OneVsOneExactPriceFixed game = new OneVsOneExactPriceFixed(stake, treasury);
        address initiator = address(0x111A);
        address opponent = address(0x222B);
        stake.mint(initiator, 10 ether);
        stake.mint(opponent, 10 ether);
        stake.approveFor(initiator, address(game), 10 ether);
        stake.approveFor(opponent, address(game), 10 ether);
        game.createGame(initiator, opponent, 90, 110, 10 ether);
        game.finalize(100 * 1e14);
        assertEq(stake.balanceOf(initiator), 10 ether, "initiator refunded");
        assertEq(stake.balanceOf(opponent), 10 ether, "opponent refunded");
        assertEq(stake.balanceOf(address(treasury)), 0, "nothing left");
    }
}
