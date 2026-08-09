// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    OstiumVault,
    OstiumVaultFixed,
    MiniToken
} from "./65201-h-03-lp-providers-will-not-get-liquidation-fee-most-times-pa.sol";

contract OstiumLiquidationFeeStuckTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant SUPPLY = 1_000e6;
    uint256 internal constant FEE = 3e6; // 3 USDC

    function test_exploit_liquidationFeeStuck_lpValueUnchanged() public {
        Exploit e = new Exploit();
        e.run();

        // --- BUGGY: the fee entered the vault but the LP claimable value is flat ---
        assertEq(e.feeStuck(), FEE, "fee entered the buggy vault");
        assertEq(e.lpDeltaBuggy(), 0, "LP claimable value unchanged (fee stuck)");
        assertEq(e.lpValueBuggyBefore(), e.lpValueBuggyAfter(), "LP value before == after");

        // Real USDC is genuinely stuck: the vault holds the 3 USDC fee yet the LP
        // (holding all shares) can still only redeem the pre-fee amount.
        MiniToken usdc = MiniToken(e.usdcAddr());
        OstiumVault vault = OstiumVault(e.vaultAddr());
        assertEq(usdc.balanceOf(address(vault)), FEE, "vault holds the fee");
        assertEq(vault.convertToAssets(SUPPLY), e.lpValueBuggyBefore(), "LP cannot redeem the fee");

        // --- CONTROL (fix): the same fee via the reward path pays the LP in full ---
        assertEq(e.lpDeltaFixed(), FEE, "fixed vault credits the LP the full fee");
        assertGt(e.lpDeltaFixed(), e.lpDeltaBuggy(), "fix pays LP; bug does not");

        // --- harm marker: 3 LOCKED-USDC recorded at SINK = the reward LPs were denied ---
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), FEE, "SINK marker records the denied reward");
        assertEq(e.sinkMarkerBalance(), FEE, "denied reward magnitude == fee");
    }

    function test_control_fixedVault_directRewardPathPaysLp() public {
        // Independent reconstruction of the negative control at the test level:
        // an over-collateralized (net-negative trader PnL) vault where the fixed
        // entrypoint routes the fee through the reward path.
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        OstiumVaultFixed vault = new OstiumVaultFixed(address(usdc));

        vault.mintShares(address(0xA11), SUPPLY);
        vault.seedState(-100e15, -100e15, 0, 0); // traders in loss, threshold 0

        usdc.mint(address(this), FEE);
        usdc.approve(address(vault), FEE);

        uint256 before = vault.convertToAssets(SUPPLY);
        vault.receiveAssets(FEE, address(0xB0B));
        uint256 afterVal = vault.convertToAssets(SUPPLY);

        assertEq(afterVal - before, FEE, "fixed: LP claimable value rises by the full fee");
    }
}
