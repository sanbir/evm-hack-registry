// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Credits, SplitQueue, Lending} from "./35023-h-2-split-transactions-fixed-fees-undercharge-block-stuff-do.sol";

contract Finding35023Test is Test {
    function test_exploit_stuff_keeps_collateral_and_underpays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.feesPaid(), 80_000_000, "8 splits paid 80 credits");
        assertEq(e.congestionWouldHavePaid(), 1_600_000_000, "congestion price was 1600 credits");
        assertEq(e.badDebt(), 1_000_000_000, "full 1000 credit debt is unpaid");
        assertEq(e.kept(), 800_000_000, "borrower kept 800 credits of collateral");
        assertTrue(e.landed() == false, "liquidation did not land");
    }

    function test_control_liquidation_seizes_the_collateral() public {
        Credits fees = new Credits();
        Credits collateral = new Credits();
        SplitQueue queue = new SplitQueue(fees);
        Lending market = new Lending(queue, collateral);
        fees.mint(address(market), queue.CONGESTION_FEE());
        collateral.mint(address(market), market.COLLATERAL());
        uint256 seized = market.liquidate(address(this));
        assertEq(seized, 800_000_000, "liquidator seized 800");
        assertEq(market.badDebt(), 200_000_000, "only the 200 shortfall remains");
        assertTrue(market.liquidated(), "position is liquidated");
        vm.expectRevert(bytes("seized"));
        market.reclaim(address(this));
    }
}
