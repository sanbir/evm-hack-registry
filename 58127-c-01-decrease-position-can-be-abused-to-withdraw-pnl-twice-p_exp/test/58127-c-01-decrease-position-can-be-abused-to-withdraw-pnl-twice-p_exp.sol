// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, GNSDiamond, MiniToken} from "./58127-c-01-decrease-position-can-be-abused-to-withdraw-pnl-twice-p.sol";

// Gains Network gTrade C-01 (finding 58127): DecreasePositionSizeUtils.prepareCallbackValues
// computes existingPnlCollateral from openPrice*collateralAmount without subtracting the
// trader's already-realized realizedPnlCollateral, so a decrease pays the same PnL twice.
// Two identical positions (each carrying 50e18 already-realized PnL) are fully decreased:
// the verbatim (buggy) diamond over-pays 50e18 and drains it from other traders' collateral.
contract Finding58127Test is Test {
    function test_exploit_decreaseWithdrawsPnlTwice() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("buggy payout", e.buggyPayout());
        emit log_named_uint("fixed payout", e.fixedPayout());
        emit log_named_uint("double-withdrawn PnL", e.doubleWithdrawnPnl());
        emit log_named_uint("buggy reserve drain", e.buggyReserveDrain());
        emit log_named_uint("fixed reserve drain", e.fixedReserveDrain());

        assertEq(e.buggyPayout(), 200 ether, "verbatim path over-pays");
        assertEq(e.fixedPayout(), 150 ether, "fixed path pays honest amount");
        assertEq(e.doubleWithdrawnPnl(), 50 ether, "already-realized PnL withdrawn a second time");
        assertEq(
            e.buggyReserveDrain(),
            e.fixedReserveDrain() + 50 ether,
            "diamond over-drained by the doubled PnL"
        );
        assertGt(e.profit(), 0, "attacker profits from the double withdrawal");
    }
}
