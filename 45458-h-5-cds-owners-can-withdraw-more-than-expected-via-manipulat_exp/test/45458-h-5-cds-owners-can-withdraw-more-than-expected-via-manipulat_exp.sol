// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./45458-h-5-cds-owners-can-withdraw-more-than-expected-via-manipulat.sol";

contract Finding45458Test is Test {
    function test_exploit_replayed_excess_pays_3000_instead_of_2000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usda().balanceOf(address(this)), 3000 ether, "attacker withdrew 3000");
        assertEq(e.cds().paid(), 3000 ether, "cds paid 3000");
        assertEq(e.usda().balanceOf(address(e.cds())), 0, "nothing left for other owners");
        assertEq(e.cds().honestPayout(1000 ether), 2000 ether, "honest payout is 2000");
    }
}
