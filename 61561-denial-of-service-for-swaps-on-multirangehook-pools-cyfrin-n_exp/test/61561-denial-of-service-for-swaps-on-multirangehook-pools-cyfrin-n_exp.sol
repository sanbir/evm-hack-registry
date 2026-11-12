// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MultiRangeHookFixed,
    Pool,
    Token
} from "./61561-denial-of-service-for-swaps-on-multirangehook-pools-cyfrin-n.sol";

contract Finding61561Test is Test {
    function test_exploit_six_ranges_block_the_swap() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.hook().rangeCount(), 6, "six ranges were created");
        assertEq(e.tokenIn().balanceOf(address(e)), e.N(), "1000 IN could not be swapped");
        assertEq(e.tokenOut().balanceOf(address(e)), 0, "no output");
    }

    function test_control_five_ranges_pay_the_output() public {
        Token tokenIn = new Token("In", "IN", 18);
        Token tokenOut = new Token("Out", "OUT", 18);
        MultiRangeHookFixed hook = new MultiRangeHookFixed();
        Pool pool = new Pool(tokenIn, tokenOut, address(hook));
        tokenIn.mint(address(this), 1000 ether);
        tokenOut.mint(address(this), 1000 ether);
        tokenIn.approve(address(pool), 1000 ether);
        tokenOut.approve(address(pool), 1000 ether);
        pool.fund(1000 ether);

        for (uint256 i; i < 5; ++i) {
            hook.createRange();
        }
        (bool sixth,) = address(hook).call(abi.encodeWithSignature("createRange()"));
        assertFalse(sixth, "the sixth range is rejected");

        (bool ok, uint256 outAmt) = pool.swap(1000 ether);
        assertTrue(ok, "five ranges still swap");
        assertEq(outAmt, 1000 ether, "output is N");
        assertEq(tokenOut.balanceOf(address(this)), 1000 ether, "user received the output");
        assertEq(tokenIn.balanceOf(address(this)), 0, "user paid the input");
    }
}
