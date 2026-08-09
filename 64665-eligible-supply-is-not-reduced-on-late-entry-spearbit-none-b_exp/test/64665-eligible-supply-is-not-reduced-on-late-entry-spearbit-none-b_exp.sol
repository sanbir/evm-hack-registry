// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    RewardsEngine,
    RewardsEngineFixed,
    MiniToken
} from "./64665-eligible-supply-is-not-reduced-on-late-entry-spearbit-none-b.sol";

// Buck Labs (Strong DAO) — finding 64665:
// "Eligible supply is not reduced on late entry" (Spearbit, RewardsEngine.sol#L1257-L1274).
//
// The late-entry branch of _handleInflow marks an account ineligible without
// subtracting its prior balance from currentEligibleSupply, so globalEligibleUnits
// (the distribution denominator) is inflated. Eligible accounts are under-paid and
// the undistributed remainder is stranded (locked) in the contract.
contract EligibleSupplyLateEntryTest is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_lateEntryInflatesDenominator_underpaysAndStrands() public {
        Exploit e = new Exploit();
        e.run();

        // Eligible account C is diluted under the buggy (inflated) denominator: it
        // receives 660k instead of the fair 1,210k.
        assertEq(e.buggyPaidC(), 660_000 ether, "buggy C payout");
        assertEq(e.fixedPaidC(), 1_210_000 ether, "fixed C payout (fair share)");
        assertLt(e.buggyPaidC(), e.fixedPaidC(), "eligible account C received less than fair share");
        assertEq(e.underPaidC(), 550_000 ether, "C under-payment delta");

        // The undistributed remainder stays locked in the buggy engine; the fixed
        // engine strands nothing.
        assertEq(e.buggyStranded(), 600_000 ether, "locked remainder in buggy engine");
        assertEq(e.fixedStranded(), 0, "fixed engine strands nothing");

        // Marker token records the locked remainder magnitude at the SINK.
        MiniToken marker = MiniToken(e.markerAddr());
        assertEq(marker.balanceOf(SINK), 600_000 ether, "marker records locked remainder at SINK");

        // Real reward tokens are truly stranded: the buggy engine still holds the
        // 600k under-distributed pool.
        MiniToken reward = MiniToken(RewardsEngine(e.engineAddr()).rewardToken());
        assertEq(reward.balanceOf(e.engineAddr()), 600_000 ether, "buggy engine retains under-distributed pool");
    }

    function test_control_fixedSubtractsOnLateEntry_noUnderpayNoStrand() public {
        // Independent rebuild of the identical scenario against the FIXED engine.
        MiniToken reward = new MiniToken("Reward", "RWD");
        RewardsEngineFixed engine = new RewardsEngineFixed(address(reward));
        address A = address(0xAAAA);
        address C = address(0xCCCC);

        engine.setEpoch(100, 1100);
        engine.fund(1_320_000 ether);

        engine.setNow(0);
        engine.notifyInflow(A, 100 ether);
        engine.notifyInflow(C, 100 ether);

        engine.setNow(100);
        engine.checkpoint();
        engine.notifyInflow(A, 100 ether); // late → disqualified; supply reduced by A's balance

        engine.setNow(1100);
        address[] memory accts = new address[](2);
        accts[0] = A;
        accts[1] = C;
        engine.distribute(accts, 1_320_000 ether);

        // With the fix, C gets the fair 11/12 share, A its earned 1/12, nothing stranded.
        assertEq(reward.balanceOf(C), 1_210_000 ether, "fixed C fair share");
        assertEq(reward.balanceOf(A), 110_000 ether, "fixed A earned share");
        assertEq(reward.balanceOf(address(engine)), 0, "fixed engine strands nothing");
    }
}
