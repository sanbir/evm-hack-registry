// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, FixedRouter, BerabotRouter} from
    "./45354-h-01-berabotrouter-calculation-for-paths-longer-than-two-is.sol";

contract Finding45354Test is Test {
    function test_multihop_pays_dust_and_keeps_weth() public {
        Exploit e = new Exploit();
        uint256 wethBefore = e.weth().balanceOf(address(e.pair1()));
        e.run();

        assertEq(e.weth().balanceOf(address(e)), 0, "user spent 1 WETH");
        assertEq(e.weth().balanceOf(address(e.pair1())), wethBefore + 1 ether, "pair1 gained 1 WETH");
        assertGt(e.fairDai(), 1_000 ether, "fair multi-hop is large");
        assertLt(e.gotDai() * 1_000, e.fairDai(), "received less than 0.1% of fair DAI");
        assertEq(e.dai().balanceOf(address(e)), e.gotDai(), "user holds only the dust");
        emit log_named_uint("fair DAI", e.fairDai());
        emit log_named_uint("got DAI", e.gotDai());
    }

    function test_control_chained_amount_in_pays_fair_dai() public {
        Exploit e = new Exploit();
        FixedRouter fixedRouter = new FixedRouter(e.router());
        address[] memory path = new address[](3);
        path[0] = address(e.weth());
        path[1] = address(e.doge());
        path[2] = address(e.dai());
        uint256 fair = e.router().quote(1 ether, path);
        e.weth().approve(address(fixedRouter), 1 ether);
        // The exploit already holds the only WETH. Transfer it to this test by running quote only.
        // Re-mint via the token's open mint, matching the same reserves path on a fresh holder.
        e.weth().mint(address(this), 1 ether);
        e.weth().approve(address(fixedRouter), 1 ether);
        uint256 got = fixedRouter.swap(1 ether, path);
        assertEq(got, fair, "chained amountIn matches the quote");
        assertGt(got, 1_000 ether, "user receives the real multi-hop output");
    }
}
