// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, FullRangeHook, TickMath} from
    "./61556-manipulation-of-price-outside-of-the-fullrangehook-liquidity.sol";

contract Finding61556Test is Test {
    function test_exploit_outside_price_mint_reverts() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.mintReverted(), "mint reverted");
        assertEq(e.quoted(), 5, "liquidity 5");
        assertEq(e.token0().balanceOf(address(this)), 100e18, "100 token0 stayed");
        assertEq(e.token1().balanceOf(address(e)), 100e18, "100 token1 stayed on the exploit");
        assertEq(e.hook().totalLp(), 0, "no LP");
        assertEq(e.token0().balanceOf(address(e.hook())), 0, "hook empty");
    }

    function test_control_in_range_mint_succeeds() public {
        Token token0 = new Token();
        Token token1 = new Token();
        FullRangeHook hook = new FullRangeHook(token0, token1);
        uint256 deposit = hook.DEPOSIT();
        token0.mint(address(this), deposit);
        token1.mint(address(this), deposit);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);

        assertEq(hook.sqrtPriceX96(), hook.SQRT_PRICE_1_1(), "price starts in range");
        uint128 quoted = hook.quote(deposit, deposit);
        assertGt(quoted, uint128(hook.MINIMUM_LIQUIDITY()), "in-range liquidity clears the minimum");

        uint256 minted = hook.mint(address(this), deposit, deposit);
        assertEq(minted, uint256(quoted) - hook.MINIMUM_LIQUIDITY(), "lp is liquidity minus 1000");
        assertEq(hook.lpOf(address(this)), minted, "lp credited");
        assertEq(token0.balanceOf(address(hook)), deposit, "hook took token0");
        assertEq(token1.balanceOf(address(hook)), deposit, "hook took token1");
        assertEq(token0.balanceOf(address(this)), 0, "depositor spent token0");
        assertTrue(hook.minted(), "mint completed");
        assertLt(TickMath.getSqrtPriceAtTick(887220), TickMath.getSqrtPriceAtTick(887272), "hook max is inside uniswap max");
    }
}
