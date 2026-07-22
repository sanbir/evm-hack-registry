// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29589-h-01-liquidations-can-be-prevented-by-frontrunning-and-liqui.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-01] Liquidations can be prevented by
    frontrunning and liquidating 1 debt due to wrong assumption in
    POS_MANAGER. Finding #29589 (code4rena, 0x73696d616f) — HIGH.
//////////////////////////////////////////////////////////////*/
contract FrontrunLiquidationTest is Test {
    MockLendingPool pool;
    PosManagerVuln posManager;
    uint constant POS_ID = 1;

    function setUp() public {
        pool = new MockLendingPool();
        posManager = new PosManagerVuln();
    }

    /// @notice CONTROL: a single, non-front-run, full liquidation of the same
    ///         underwater position succeeds without reverting. This proves the
    ///         bug is specifically the 1-share-frontrun sequence, not a general
    ///         inability to liquidate.
    function test_control_directFullLiquidation_succeeds() public {
        posManager.updatePosDebtShares(POS_ID, address(pool), int(uint(1_000_000)));
        pool.borrow(1_000_000);
        pool.accrueInterest(100_000);

        // direct full liquidation, no frontrun
        posManager.updatePosDebtShares(POS_ID, address(pool), -int(uint(1_000_000)));
        pool.repay(1_000_000);

        assertEq(posManager.debtShares(POS_ID, address(pool)), 0, "position should be fully liquidated");
    }

    /// @notice HARM: front-running the real liquidation with a 1-share
    ///         self-liquidation permanently blocks the honest liquidator's
    ///         attempt to fully liquidate the position (underflow revert).
    function test_frontrunLiquidation_blocksHonestLiquidation() public {
        Exploit exploit = new Exploit();
        exploit.run();

        assertTrue(exploit.honestLiquidationReverted(), "honest liquidation should have reverted");
        (MockLendingPool p, PosManagerVuln pm) = (exploit.pool(), exploit.posManager());
        assertEq(pm.debtShares(exploit.POS_ID(), address(p)), 999_999, "position should remain un-liquidated");
    }
}
