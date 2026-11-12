// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./58129-h-02-gettradeskewpriceimpactp-function-ignores-trade-contrac.sol";

contract Finding58129Test is Test {
    function test_exploit_legacy_close_pays_half_skew() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.impactVuln(), -1e8, "charged 1% skew");
        assertEq(e.impactControl(), 0, "v9 close should be 0");
        assertEq(e.extraFill(), 1_000e18, "extra fill is 1000 DAI");
        assertEq(e.controlFill(), 0, "control fill");
        assertEq(e.book().fillTaken(), 1_000e18, "book took the fill");
    }
}
