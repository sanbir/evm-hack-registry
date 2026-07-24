// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./16038-h-01-bond-max-buyer-might-end-up-buying-the-max-buy-of-the-n.sol";

contract MuteBondMaxBuyTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimPayout(), e.MAX_PAYOUT(), "bought full next epoch");
        assertGt(e.victimPayout(), e.INTENDED(), "larger than intended remainder");
    }
}
