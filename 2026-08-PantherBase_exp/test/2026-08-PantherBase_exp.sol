// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, RealityModule, Safe, ZKP} from "./2026-08-PantherBase.sol";

contract PantherBaseTest is Test {
    function test_exploit_unopposedSelfAnswer_capturesGovernance() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_decimal_uint("ZKP moved from Safe", e.moved(), 18);
        emit log_named_decimal_uint("attacker ZKP captured", e.profit(), 18);
        assertEq(e.profit(), 5120000e18, "must capture 5.12M ZKP");
    }
}
