// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64854-h-06-donations-to-distributor-with-arbitrary-quotetoken-can.sol";

contract DistributorFakeQuoteTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertGe(e.stolen(), 4_000e18, "must drain real quote rewards via fake token1");
    }
}
