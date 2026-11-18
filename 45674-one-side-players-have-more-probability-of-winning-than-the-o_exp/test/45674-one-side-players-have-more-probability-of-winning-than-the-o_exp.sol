// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, PriceOracle, Treasury, UpDownFixed, UpBettor} from
    "./45674-one-side-players-have-more-probability-of-winning-than-the-o.sol";

contract Finding45674Test is Test {
    function test_exploit_tie_pays_down_the_whole_pot() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.scaledFinal(), e.scaledStart(), "tie");
        assertEq(e.downGot(), 100 ether, "down received 100");
        assertEq(e.upGot(), 0, "up received 0");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.up())), 0, "up broke");
    }

    function test_control_tie_refunds_both_sides() public {
        Token token = new Token();
        PriceOracle oracle = new PriceOracle(1000 ether);
        Treasury treasury = new Treasury(token);
        UpDownFixed game = new UpDownFixed(oracle, treasury, token);
        UpBettor up = new UpBettor();

        token.mint(address(up), 50 ether);
        token.mint(address(this), 50 ether);
        up.bet(token, game, 50 ether);
        token.approve(address(game), 50 ether);
        game.betDown(50 ether);
        game.finalizeGame();

        assertEq(token.balanceOf(address(up)), 50 ether, "up refunded");
        assertEq(token.balanceOf(address(this)), 50 ether, "down refunded");
        assertEq(token.balanceOf(address(treasury)), 0, "treasury empty");
    }
}
