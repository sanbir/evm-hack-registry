// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FullRangeHookFixed, Token} from "./61558-swaps-performed-in-pools-with-zero-liquidity-can-cause-a-com.sol";

contract Finding61558Test is Test {
    function test_exploit_zero_liq_swap_bricks_the_deposit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.hook().liquidity(), 0, "position stayed empty");
        assertTrue(e.hook().hasAccruedFees(), "flag was set by the empty swap");
        assertEq(e.token().balanceOf(address(e)), e.N(), "1000 LP stays with the depositor");
        assertEq(e.token().balanceOf(address(e.hook())), 0, "hook holds nothing");
    }

    function test_control_rejects_zero_liquidity() public {
        Token token = new Token("Liquidity", "LP", 18);
        FullRangeHookFixed hook = new FullRangeHookFixed(token);
        token.mint(address(this), 1000 ether);
        token.approve(address(hook), 1000 ether);

        (bool swapped,) = address(hook).call(abi.encodeWithSignature("beforeSwap()"));
        assertFalse(swapped, "control rejects zero liquidity");
        assertFalse(hook.hasAccruedFees(), "flag stays clear");

        hook.addLiquidity(1000 ether);
        assertEq(hook.liquidity(), 1000 ether, "deposit lands");
        assertEq(token.balanceOf(address(hook)), 1000 ether, "hook holds N");
        assertEq(token.balanceOf(address(this)), 0, "depositor paid N");
    }
}
