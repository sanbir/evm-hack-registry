// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Goat} from "./40666-when-stake-eth-in-earningreinvest-the-reduction-of-maxearnin.sol";

contract Finding40666Test is Test {
    function test_user_earns_above_the_reduced_cap() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.credited(), 1090, "credited earning");
        assertEq(e.brokenCap(), 1090, "stored cap overwritten");
        assertEq(e.fairCap(), 90, "cap after a real reduction");
        assertGt(e.brokenCap(), e.fairCap(), "1090 is above 90");
        console2.log("credited earning", e.credited());
        console2.log("broken maxEarning", e.brokenCap());
        console2.log("reduced cap", e.fairCap());
    }

    function test_control_reduces_the_cap() public {
        Goat g = new Goat();
        g.seed(address(this));
        g.earningReinvestFixed(true, payable(address(0xB0B)), 100, 1000, 0, 0);

        assertEq(g.earning().sharedA(address(this)), 1090, "same credited earning");
        assertEq(g.earning().maxEarningOf(address(this)), 90, "cap reduced to 90");
        assertGt(g.earning().sharedA(address(this)), g.earning().maxEarningOf(address(this)), "earning above cap");
        console2.log("control credited", g.earning().sharedA(address(this)));
        console2.log("control cap", g.earning().maxEarningOf(address(this)));
    }
}
