// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    MiniToken,
    ElytraDepositPoolV1,
    ElytraUnstakingVaultV1
} from "./63544-h-01-tvl-double-counts-assets-returned-from-strategy-to-vaul.sol";

// Elytra [H-01]: TVL double-counts assets returned from strategy to vault.
//
// ElytraUnstakingVaultV1.receiveFromStrategy increments claimableAssets but never
// decrements ElytraDepositPoolV1.assetsAllocatedToStrategies. getTotalAssetTVL sums
// both, so strategy-returned assets are counted twice: TVL reports 200e18 while the
// protocol truly holds 100e18. The 100e18 phantom over-report is the accounting
// corruption that mis-prices elyAsset.
contract ElytraTVLDoubleCountTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_tvlDoubleCountsStrategyReturn() public {
        Exploit e = new Exploit();
        e.run();

        // HARM: reported TVL is 200e18 while real ERC20 holdings (pool + vault) are 100e18.
        assertEq(e.buggyTVL(), 200 ether, "TVL double-counts returned assets");
        assertEq(e.realHoldings(), 100 ether, "real holdings are only the 100e18 returned");
        assertGt(e.buggyTVL(), e.realHoldings(), "TVL over-reports real holdings");
        assertEq(e.overReport(), 100 ether, "phantom over-report equals the returned amount");

        // Root cause: BOTH contributors are the same 100e18 (double count).
        assertEq(e.buggyStrategyAllocated(), 100 ether, "strategy allocation never settled after return");
        assertEq(e.buggyVaultClaimable(), 100 ether, "vault claimable holds the same returned amount");

        // Cross-check straight off the deployed buggy contracts.
        ElytraDepositPoolV1 pool = ElytraDepositPoolV1(e.buggyPoolAddr());
        ElytraUnstakingVaultV1 vault = ElytraUnstakingVaultV1(e.buggyVaultAddr());
        address asset = e.buggyAssetAddr();
        assertEq(pool.assetsAllocatedToStrategies(asset), 100 ether, "allocation live on-chain");
        assertEq(vault.getClaimableAssets(asset), 100 ether, "claimable live on-chain");
        assertEq(pool.getTotalAssetTVL(asset), 200 ether, "live TVL double-counts");

        // The phantom over-report is recorded on the marker token at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 100 ether, "marker records phantom TVL at SINK");
        assertEq(e.sinkMarkerBalance(), 100 ether, "sink marker balance matches over-report");
    }

    function test_control_fixedReceiveFromStrategy_noDoubleCount() public {
        // The Exploit also runs the FIXED variant; assert it reports true holdings.
        Exploit e = new Exploit();
        e.run();

        // Negative control: fixed receiveFromStrategy settles the allocation, so
        // getTotalAssetTVL equals the real 100e18 (no double-count).
        assertEq(e.fixedTVL(), 100 ether, "fixed TVL equals real holdings");
        assertLt(e.fixedTVL(), e.buggyTVL(), "fix removes the phantom over-report");
    }
}
