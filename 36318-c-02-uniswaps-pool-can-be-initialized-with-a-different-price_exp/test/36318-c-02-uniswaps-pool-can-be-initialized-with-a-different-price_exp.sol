// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./36318-c-02-uniswaps-pool-can-be-initialized-with-a-different-price.sol";

contract SeriousSkewedPriceExpTest is Test {
    function test_attacker_drains_disproportionate_weth_via_skewed_price() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.wethUsedInPool(), 10 ether);
        assertLt(e.tokenUsedInPool(), 1_000_000e18);
        assertEq(e.wethDrained(), 7 ether);
    }

    /// @dev Control: if the market itself creates+initializes the pool FIRST
    ///      (nothing has pre-empted it), liquidity is added at the intended
    ///      1:1 price and a 1-token swap yields only ~1 WETH, not 7.
    function test_control_no_front_run_price_is_normal() public {
        MockToken token = new MockToken();
        MockToken weth = new MockToken();
        SkewablePool pool = new SkewablePool(token, weth);
        SeriousMarketProtocol2 market = new SeriousMarketProtocol2(pool, token, weth);

        weth.mint(address(market), 10 ether);
        token.mint(address(market), 1_000_000e18);
        token.mint(address(this), 1e18);

        (uint256 tUsed, uint256 wUsed) = market.createPoolAndAddLiquidity();
        // At the intended 1:1 price, the 10 ETH target is still the limiting
        // side (the token target is far larger), but ONLY 10 tokens (not a
        // tiny fraction) are needed to match it -- versus ~1.43 tokens at the
        // attacker's skewed 7x price in the main exploit.
        assertEq(wUsed, 10 ether);
        assertEq(tUsed, 10 ether); // 1:1 price -> tokenUsed == wethUsed in these abstract units

        token.approve(address(pool), 1e18);
        uint256 before = weth.balanceOf(address(this));
        pool.swap(address(this), 1e18);
        uint256 out = weth.balanceOf(address(this)) - before;
        assertEq(out, 1e18); // 1:1 price -> 1 token in yields 1 WETH out, not 7
    }
}
