// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    DaosLive,
    Exploit,
    SnipeToken,
    SwapRouter,
    Treasury
} from "./57868-h-01-swapped-tokens-during-finalize-permanently-stuck-in-dao.sol";

contract Finding57868Test is Test {
    function test_sniped_tokens_stay_on_the_contract() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stuck(), 1000 ether, "1000 stuck");
        assertTrue(e.sweepMissing(), "sweep is missing");
        assertEq(e.token().balanceOf(address(e.dao())), 1000 ether, "dao still holds 1000");
        assertEq(e.token().balanceOf(address(e.treasury())), 0, "treasury holds 0");
    }

    function test_control_sends_the_tokens_to_the_treasury() public {
        SnipeToken token = new SnipeToken();
        SwapRouter router = new SwapRouter(token);
        Treasury treasury = new Treasury();
        DaosLive dao = new DaosLive(router, token, treasury, 1000 ether, true);
        uint256 out = dao.finalize();

        assertEq(out, 1000 ether, "swap returned 1000");
        assertEq(token.balanceOf(address(treasury)), 1000 ether, "treasury holds 1000");
        assertEq(token.balanceOf(address(dao)), 0, "contract holds 0");
    }
}
