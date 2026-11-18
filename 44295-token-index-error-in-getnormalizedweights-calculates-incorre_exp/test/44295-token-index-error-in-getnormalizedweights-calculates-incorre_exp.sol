// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./44295-token-index-error-in-getnormalizedweights-calculates-incorre.sol";
contract Finding44295Test is Test {
    function test_token4_weight_uses_itself_as_multiplier() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.buggyWeight(), 6e17);
        assertEq(e.paid(), 600e18);
        assertEq(e.token().balanceOf(address(e)), 600e18);
        assertEq(e.token().balanceOf(address(e.pool())), 400e18);
    }
    function test_control_multiplier_index_stays_4() public {
        // secondFourWeights[4] == 0, so the fair interpolation is the raw weight
        assertEq((uint256(1000e18) * uint256(2e17)) / 1e18, uint256(200e18));
    }
}
