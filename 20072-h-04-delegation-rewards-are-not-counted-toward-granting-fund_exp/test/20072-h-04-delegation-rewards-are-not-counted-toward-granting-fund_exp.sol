// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20072-h-04-delegation-rewards-are-not-counted-toward-granting-fund.sol";

/*//////////////////////////////////////////////////////////////
    Ajna Grants — [H-04] Delegation rewards are not counted toward
    granting fund. Finding 20072 (Code4rena 2023-05, reporter REACH) — HIGH

    _updateTreasury re-adds `fundsAvailable - totalTokensRequested` (~10% of the
    GBC) to the treasury each period, ignoring the delegate rewards actually paid
    out by claimDelegateReward. The treasury's booked balance therefore drifts
    above the AJNA it holds by exactly the delegate rewards, every period.
//////////////////////////////////////////////////////////////*/
contract AjnaTreasuryOverAccountingTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_treasury_overAccounts_by_delegateRewards() public {
        exp.run();

        uint256 firstGbc = exp.firstGbc();
        uint256 delegateRewardsPaid = exp.delegateRewardsPaid();
        uint256 booked = exp.bookedAfterUpdate();
        uint256 real = exp.realBalance();

        emit log_named_uint("GBC (3% of 500M)", firstGbc);
        emit log_named_uint("delegate rewards paid (10% of GBC)", delegateRewardsPaid);
        emit log_named_uint("treasury booked (free + reserved)", booked);
        emit log_named_uint("real AJNA balance", real);
        emit log_named_uint("over-accounting (booked - real)", booked - real);

        // Concrete numbers from the finding: GBC = 15M, delegate rewards = 1.5M.
        assertEq(firstGbc, 15_000_000 ether, "GBC = 3% of 500M");
        assertEq(delegateRewardsPaid, 1_500_000 ether, "delegate rewards = 10% of GBC");

        // The treasury books more AJNA than it holds, by exactly the delegate rewards.
        assertGt(booked, real, "treasury is over-accounted");
        assertEq(booked - real, delegateRewardsPaid, "over-accounting == delegate rewards paid");
        assertEq(booked - real, 1_500_000 ether, "1.5M AJNA phantom per period");
    }

    function test_multiPeriod_drift_compounds() public {
        // The gap is per-period; over many periods the treasury books far more
        // than it holds. Run one period via the Exploit, then confirm the invariant
        // `treasury book <= real balance` is broken.
        exp.run();
        assertGt(exp.bookedAfterUpdate(), exp.realBalance(), "solvency invariant broken");
    }
}
