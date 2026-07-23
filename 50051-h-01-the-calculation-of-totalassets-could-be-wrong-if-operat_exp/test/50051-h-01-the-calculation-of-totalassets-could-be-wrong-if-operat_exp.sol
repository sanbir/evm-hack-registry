// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./50051-h-01-the-calculation-of-totalassets-could-be-wrong-if-operat.sol";

/* Liquid Ron H-01 — totalAssets includes operatorFeeAmount (Code4rena 2025-01) */
contract PoC_50051 is Test {
    function test_totalAssetsFeeDilution() public {
        Exploit e = new Exploit();
        // Fund exploit with enough ETH for two 100-ether deposits + 10 ether fee inject
        vm.deal(address(e), 250 ether);
        e.run();

        assertGt(e.expectedRedeem(), e.actualRedeem());
        assertGt(e.loss(), 0);
        // Loss is on the order of the fee share of the new deposit (~0.9+ ether for 100/110)
        assertGt(e.loss(), 0.5 ether);
    }
}
