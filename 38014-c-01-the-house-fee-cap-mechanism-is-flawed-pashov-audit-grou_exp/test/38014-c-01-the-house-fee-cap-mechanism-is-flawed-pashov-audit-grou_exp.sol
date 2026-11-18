// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./38014-c-01-the-house-fee-cap-mechanism-is-flawed-pashov-audit-grou.sol";

contract Finding38014Test is Test {

    function test_exploit_caps_mont_at_usdt_amount() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.uncapped(), 5000 ether, "expected");
        assertEq(e.paid(), 11_800_000, "capped");
        assertEq(e.mont().balanceOf(address(this)), 11_800_000, "player");
        assertEq(e.fair(), 5000 ether, "control");
        assertLt(e.paid(), e.uncapped(), "short");
    }

}
