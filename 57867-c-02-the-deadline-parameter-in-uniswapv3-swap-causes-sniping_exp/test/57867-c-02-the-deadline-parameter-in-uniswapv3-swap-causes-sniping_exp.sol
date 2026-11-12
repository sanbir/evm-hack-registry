// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DaosLive, Exploit, SnipeToken, SwapRouter} from "./57867-c-02-the-deadline-parameter-in-uniswapv3-swap-causes-sniping.sol";

contract Finding57867Test is Test {
    function test_zero_deadline_moves_zero_tokens() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.past(), "stored deadline is behind the block timestamp");
        assertTrue(e.snipeReverted(), "snipe reverts");
        assertEq(e.moved(), 0, "0 tokens moved");
        assertEq(e.token().balanceOf(address(e.dao())), 0, "dao received nothing");
    }

    function test_control_live_deadline_moves_N_and_the_past_deadline_reverts() public {
        SnipeToken token = new SnipeToken();
        SwapRouter router = new SwapRouter(token);
        DaosLive dao = new DaosLive(router, token, 1000 ether, true);
        uint256 moved = dao.finalize();
        assertEq(moved, 1000 ether, "control moves N");
        assertEq(token.balanceOf(address(dao)), 1000 ether, "dao holds N");

        dao.arm(0);
        assertGt(block.timestamp, dao.storedDeadline(), "stored deadline is in the past");
        vm.expectRevert(bytes("Transaction too old"));
        dao.finalizeAtStored();
    }
}
