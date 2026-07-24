// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35207-h-05-triggerfee-is-stolen-from-other-auctions-during-settlew.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-05] — settleWithBuyout triggerFee drains other auctions.

    Re-asserts: originator balance == fee, shared escrow shortfall == fee.
//////////////////////////////////////////////////////////////////////////*/
contract TriggerFeeTheftTest is Test {
    function test_settleWithBuyout_steals_triggerFee_from_other_auction() public {
        Exploit exp = new Exploit();
        exp.run();

        uint256 expectedFee = (exp.AUCTION_B_OWED() * exp.TRIGGER_FEE_BPS()) / 10_000;
        assertEq(exp.feeStolen(), expectedFee, "fee amount");
        assertEq(exp.originatorBalance(), expectedFee, "originator paid from contract");
        assertEq(exp.auctionAShortfall(), expectedFee, "other auction shortfall");
    }
}
