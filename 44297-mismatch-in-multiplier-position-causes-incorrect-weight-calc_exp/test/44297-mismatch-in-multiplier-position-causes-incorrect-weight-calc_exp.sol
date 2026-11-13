// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, SwapToken, WeightedPoolFixed} from
    "./44297-mismatch-in-multiplier-position-causes-incorrect-weight-calc.sol";

contract Finding44297Test is Test {
    function test_exploit_token5_swap_pays_1_03() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 1.03 ether, "out");
        assertEq(e.token0().balanceOf(address(e)), 1.03 ether, "balance");
    }

    function test_control_multiplier_lane_pays_1_to_1() public {
        SwapToken token0 = new SwapToken("T0");
        WeightedPoolFixed fixedP = new WeightedPoolFixed(token0);
        token0.mint(address(fixedP), 10 ether);
        int256 w = int256(1e18) / 6;
        int256 m = 0.001e18;
        int256[] memory weights = new int256[](12);
        for (uint256 i; i < 6; i++) {
            weights[i] = w;
            weights[i + 6] = m;
        }
        fixedP.setWeights(weights);
        uint256 out = fixedP.onSwap(5, 0, 1 ether);
        assertEq(out, 1 ether, "fair");
        assertEq(fixedP.currentWeight(5), fixedP.currentWeight(0), "same weight");
    }
}
