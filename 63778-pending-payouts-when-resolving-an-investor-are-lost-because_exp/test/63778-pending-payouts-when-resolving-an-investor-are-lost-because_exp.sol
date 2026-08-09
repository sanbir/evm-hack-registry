// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    DividendManager,
    DividendManagerFixed,
    MiniToken,
    Investor
} from "./63778-pending-payouts-when-resolving-an-investor-are-lost-because.sol";

contract ResolvedPayLockedTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant OLD = 0x000000000000000000000000000000000000010D;
    address internal constant OLD2 = 0x000000000000000000000000000000000000020d;

    uint256 internal constant P = 1_000_000000; // 1,000 USDC (6 decimals)

    /// @dev The migrated payout is orphaned in _resolvedPay and permanently
    ///      locked in the manager; the newAddress can never claim it.
    function test_exploit_resolvedPay_isPermanentlyLocked() public {
        Exploit e = new Exploit();
        e.run();

        // The payout WAS recorded against the new address...
        assertEq(e.resolvedPayForNew(), uint128(P), "payout recorded to _resolvedPay[new]");
        // ...but the new address received nothing when claiming through the only path.
        assertEq(e.newReceived(), 0, "new address claimed nothing");
        // The P dividend tokens are still trapped inside the manager.
        assertEq(e.contractLocked(), P, "P locked in the manager");

        // Independently re-verify the on-chain state (not just the Exploit's echo).
        DividendManager dm = DividendManager(e.dmAddr());
        MiniToken usdc = MiniToken(e.usdcAddr());
        assertEq(usdc.balanceOf(e.newInvestorAddr()), 0, "new investor holds 0 dividend tokens");
        assertEq(usdc.balanceOf(e.dmAddr()), P, "manager still holds the full owed amount");
        assertEq(dm.pendingOf(e.newInvestorAddr()), 0, "new investor has no reachable pending");
        assertEq(dm.pendingOf(OLD), 0, "old holder's pending was consumed by _resolvePay");

        // Marker records the locked magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), P, "marker records locked amount at SINK");
        assertEq(e.sinkMarkerBalance(), P, "sink marker balance echoes locked amount");
    }

    /// @dev Negative control: with the fix, claimPayout drains _resolvedPay, so
    ///      the new address DOES receive the migrated payout — nothing is locked.
    function test_control_fixed_newAddressClaimsMigratedPayout() public {
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        DividendManagerFixed dm = new DividendManagerFixed(address(usdc));
        Investor investor = new Investor();

        dm.setPending(OLD, P);
        usdc.mint(address(dm), P);

        dm.resolveUser(OLD, address(investor));
        assertEq(dm.resolvedPayOf(address(investor)), uint128(P), "payout recorded");

        uint256 before = usdc.balanceOf(address(investor));
        investor.claim(address(dm));
        uint256 received = usdc.balanceOf(address(investor)) - before;

        assertEq(received, P, "fixed: new address receives the migrated payout");
        assertEq(usdc.balanceOf(address(dm)), 0, "fixed: nothing locked in the manager");
        assertEq(dm.resolvedPayOf(address(investor)), 0, "fixed: _resolvedPay drained on claim");
    }

    /// @dev Variant: resolving TWO old accounts to the SAME new address. The
    ///      buggy contract OVERWRITES _resolvedPay, so even a hypothetical reader
    ///      could recover only the second amount — the first is destroyed. The
    ///      fix accumulates and pays out the full sum.
    function test_variant_secondResolveOverwritesFirst() public {
        // ---- buggy: second _resolvePay overwrites the first ----
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6);
        DividendManager dm = new DividendManager(address(usdc));
        Investor investor = new Investor();

        uint256 p1 = 400_000000; // 400 USDC
        uint256 p2 = 600_000000; // 600 USDC
        dm.setPending(OLD, p1);
        dm.setPending(OLD2, p2);
        usdc.mint(address(dm), p1 + p2);

        dm.resolveUser(OLD, address(investor));
        assertEq(dm.resolvedPayOf(address(investor)), uint128(p1), "first migration recorded");
        dm.resolveUser(OLD2, address(investor));
        // Overwritten: only p2 survives in the mapping; p1 is lost.
        assertEq(dm.resolvedPayOf(address(investor)), uint128(p2), "second migration overwrote the first");

        // Both are unclaimable anyway (no reader), so all p1+p2 stays locked.
        investor.claim(address(dm));
        assertEq(usdc.balanceOf(address(investor)), 0, "buggy: new address claimed nothing");
        assertEq(usdc.balanceOf(address(dm)), p1 + p2, "buggy: full sum locked");

        // ---- fixed: accumulate + claimable ----
        MiniToken usdc2 = new MiniToken("USD Coin", "USDC", 6);
        DividendManagerFixed dmf = new DividendManagerFixed(address(usdc2));
        Investor investor2 = new Investor();

        dmf.setPending(OLD, p1);
        dmf.setPending(OLD2, p2);
        usdc2.mint(address(dmf), p1 + p2);

        dmf.resolveUser(OLD, address(investor2));
        dmf.resolveUser(OLD2, address(investor2));
        assertEq(dmf.resolvedPayOf(address(investor2)), uint128(p1 + p2), "fixed: amounts accumulate");

        investor2.claim(address(dmf));
        assertEq(usdc2.balanceOf(address(investor2)), p1 + p2, "fixed: full sum received");
        assertEq(usdc2.balanceOf(address(dmf)), 0, "fixed: nothing locked");
    }
}
