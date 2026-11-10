// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    BeetleNFT,
    Exploit,
    GameFixed,
    Opponent
} from "./62314-c-01-user-can-deny-opponent-nft-rewards-by-marking-safe-post.sol";

contract Finding62314Test is Test {
    function test_exploit_opponent_receives_no_beetle() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.opponentBalance(), 0, "opponent received nothing");
        assertEq(e.locked(), 1, "the beetle stays locked");
        assertEq(e.game().isStaked(e.TOKEN_ID()), address(e), "still staked to the loser");
        assertTrue(e.game().claimBlocked(), "claim was blocked");
    }

    function test_control_awards_the_opponent() public {
        BeetleNFT nft = new BeetleNFT();
        GameFixed game = new GameFixed(nft);
        Opponent opponent = new Opponent();
        nft.mint(address(this), 1);
        nft.approve(address(game), 1);
        game.stake(1);
        game.finishBattle(address(opponent), address(this), 1);

        vm.expectRevert(GameFixed.TooLate.selector);
        game.markBeetleSafe(1);

        opponent.claim(game, 1);
        assertEq(nft.balanceOf(address(opponent)), 1, "control pays the opponent");
        assertEq(nft.ownerOf(1), address(opponent), "opponent owns the beetle");
        assertEq(nft.balanceOf(address(game)), 0, "game no longer holds it");
    }
}
