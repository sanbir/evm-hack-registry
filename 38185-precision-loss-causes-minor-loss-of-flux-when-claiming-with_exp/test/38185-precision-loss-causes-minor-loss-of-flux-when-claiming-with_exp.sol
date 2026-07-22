// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./38185-precision-loss-causes-minor-loss-of-flux-when-claiming-with.sol";

contract PrecisionLossDustTest is Test {
    /// @notice HARM: run() proves the claimant receives strictly less FLUX
    ///         than the round-trip-free formula would produce.
    function test_exploit_claimant_loses_dust_flux() public {
        Exploit e = new Exploit();
        e.run();

        uint256 actualFlux = e.flux().balanceOf(address(e));
        uint256 bpt = (e.TOKEN_DATA() * 40) / 10_000;
        uint256 expectedFlux = (bpt * 2 * (5000 + 10_000)) / 10_000 / 4;

        assertLt(actualFlux, expectedFlux, "claimant should receive less than the round-trip-free amount");
        assertEq(expectedFlux - actualFlux, 8_292_000, "dust loss should match the exact computed shortfall");
    }

    /// @notice Isolates the exact mechanism: the redundant /veMax * veMax
    ///         round-trip truncates precision even though it is mathematically
    ///         a no-op in real-number arithmetic.
    function test_buggyFormula_loses_precision_vs_roundtripFree_formula() public {
        MockVeALCX ve = new MockVeALCX();
        PatronNFT nft = new PatronNFT();
        FluxToken flux = new FluxToken(address(ve), address(nft));

        uint256 amount = 10 ether;
        uint256 buggy = flux.getClaimableFlux(amount);

        uint256 bpt = flux.calculateBPT(amount);
        uint256 roundtripFree = (bpt * 2 * (5000 + 10_000)) / 10_000 / 4;

        assertLt(buggy, roundtripFree, "the /veMax * veMax round-trip must lose precision (dust)");
    }

    /// @notice Control: when bpt * veMul happens to be an exact multiple of
    ///         veMax, the redundant round-trip loses NO precision — confirming
    ///         the bug is specifically the truncation of a nonzero remainder.
    function test_control_noRemainder_noLoss() public view {
        uint256 veMax = 365 days;
        uint256 veMul = 2;
        // Choose bpt so that bpt * veMul is an exact multiple of veMax.
        uint256 bpt = veMax * 1000; // (bpt * veMul) % veMax == 0
        uint256 fluxPerVe = 5000;
        uint256 fluxMul = 4;
        uint256 BPS = 10_000;

        uint256 buggy = (((bpt * veMul) / veMax) * veMax * (fluxPerVe + BPS)) / BPS / fluxMul;
        uint256 roundtripFree = (bpt * veMul * (fluxPerVe + BPS)) / BPS / fluxMul;

        assertEq(buggy, roundtripFree, "no remainder means no precision loss from the round-trip");
    }
}
