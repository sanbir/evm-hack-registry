// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GameFixed, MockToken} from "./57907-h-01-predictable-randomness-in-activity-outcomes-shieldify-n.sol";

contract PredictableRollTest is Test {
    function test_exploit_attackerPicksTheWinningSalt() public {
        Exploit e = new Exploit();
        e.run();

        assertLt(e.chosenRoll(), 50, "winning roll");
        assertEq(e.paid(), 1000 ether, "paid");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "balance");
        assertGt(e.tries(), 0, "searched");
    }

    function test_control_committedSeedPaysZeroForTheSameCall() public {
        MockToken token = new MockToken();
        GameFixed game = new GameFixed(address(token));
        token.mint(address(game), 1000 ether);
        game.authorize(address(this));

        uint256 roll = uint256(keccak256(abi.encodePacked(uint256(1), uint256(1)))) % 100;
        assertEq(roll, 99, "seed 1 penguin 1 rolls 99");

        uint256 paid = game.doActivity(1, bytes32(uint256(0)), hex"01020304");
        assertEq(paid, 0, "control pays 0");
        assertEq(token.balanceOf(address(this)), 0, "caller got nothing");
        assertEq(token.balanceOf(address(game)), 1000 ether, "reward stayed");
    }
}
