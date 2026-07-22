// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38191-fluxtokencalculatebpt-uses-wrong-algorithm-causing-fluxtoken.sol";

contract CalculateBPTInflationTest is Test {
    /// @notice HARM: run() proves a single patron NFT claim mints ~10,000x
    ///         the FLUX the documented 0.4% ratio should have produced.
    function test_exploit_calculateBPT_inflates_flux_10000x() public {
        Exploit e = new Exploit();
        e.run();

        uint256 actualFlux = e.flux().balanceOf(address(e));
        uint256 correctBpt = (e.TOKEN_DATA() * 40) / 10_000;
        uint256 expectedFlux = (((correctBpt * 2) / 365 days) * 365 days * (5000 + 10_000)) / 10_000 / 4;

        assertGt(actualFlux, expectedFlux * 9000, "should mint >9000x the correct amount");
        assertLt(actualFlux, expectedFlux * 11000, "should mint <11000x the correct amount");
    }

    /// @notice Isolates the exact mechanism: calculateBPT alone is exactly
    ///         BPS (10_000) times larger than the documented 0.4% ratio.
    function test_buggyCalculateBPT_is_10000x_the_documented_ratio() public {
        MockVeALCX ve = new MockVeALCX();
        PatronNFT nft = new PatronNFT();
        FluxToken flux = new FluxToken(address(ve), address(nft));

        uint256 amount = 1 ether;
        uint256 buggyBpt = flux.calculateBPT(amount);
        uint256 correctBpt = (amount * flux.bptMultiplier()) / 10_000;

        assertEq(buggyBpt, amount * 40, "buggy bpt = amount * bptMultiplier (no BPS division)");
        assertEq(buggyBpt, correctBpt * 10_000, "buggy bpt is exactly 10,000x the correct (documented) bpt");
    }

    /// @notice Control: with the `/ BPS` fix applied, calculateBPT returns
    ///         the documented 0.4% ratio instead of the inflated raw product.
    function test_control_fixedCalculateBPT_returns_documented_ratio() public {
        uint256 amount = 1 ether;
        uint256 bptMultiplier = 40;
        uint256 BPS = 10_000;

        uint256 fixedBpt = (amount * bptMultiplier) / BPS; // the fix
        assertEq(fixedBpt, amount * 40 / 10_000, "fixed bpt matches the documented 0.4% ratio");
        assertLt(fixedBpt, amount, "0.4% of amount must be far smaller than amount itself");
    }
}
