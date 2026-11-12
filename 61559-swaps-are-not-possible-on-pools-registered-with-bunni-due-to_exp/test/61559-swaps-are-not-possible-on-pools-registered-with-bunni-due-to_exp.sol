// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    ValkyrieHookletFixed,
    Pool,
    Token
} from "./61559-swaps-are-not-possible-on-pools-registered-with-bunni-due-to.sol";

contract Finding61559Test is Test {
    function test_exploit_swap_reverts_and_N_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.tokenIn().balanceOf(address(e)), e.N(), "1000 IN stays with the user");
        assertEq(e.tokenOut().balanceOf(address(e)), 0, "user received no output");
        assertEq(e.tokenOut().balanceOf(address(e.pool())), e.N(), "output is still in the pool");
    }

    function test_control_swap_pays_the_output() public {
        Token tokenIn = new Token("In", "IN", 18);
        Token tokenOut = new Token("Out", "OUT", 18);
        ValkyrieHookletFixed hooklet = new ValkyrieHookletFixed();
        Pool pool = new Pool(tokenIn, tokenOut, address(hooklet));
        hooklet.setBunniHook(address(pool));
        tokenIn.mint(address(this), 1000 ether);
        tokenOut.mint(address(this), 1000 ether);
        tokenIn.approve(address(pool), 1000 ether);
        tokenOut.approve(address(pool), 1000 ether);
        pool.fund(1000 ether);

        (bool ok, uint256 outAmt) = pool.swap(1000 ether);
        assertTrue(ok, "control swap succeeds");
        assertEq(outAmt, 1000 ether, "output is N");
        assertEq(tokenOut.balanceOf(address(this)), 1000 ether, "user received the output");
        assertEq(tokenIn.balanceOf(address(this)), 0, "user paid the input");
    }
}
