// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27047-h-01-underflow-in-updatetranscoderwithfees-can-cause-corrupt.sol";

/*//////////////////////////////////////////////////////////////
    Livepeer — [H-01] Underflow in updateTranscoderWithFees.
    Finding 27047 (Code4rena 2023-08, reporter VAD37) — HIGH

    MathUtils.percOf on a PreciseMathUtils cut rate underflows
    rewards.sub(treasuryRewards), DoSing ticket redemption after a
    skipped reward round. Tickets expire after two rounds → fees lost.
//////////////////////////////////////////////////////////////*/
contract LivepeerTreasuryUnderflowTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_control_preciseMath_redeems() public {
        // Control: with PreciseMathUtils the same skipped-reward path pays the transcoder.
        FeeToken tok = new FeeToken();
        BondingManager bm = new BondingManager(tok);
        TicketBroker br = new TicketBroker(tok, bm);
        bm.setTicketBroker(address(br));
        bm.setTreasuryRewardCutRate(10 ** 26); // 10% precise
        address tc = address(0xCAFE);
        bm.seedTranscoder(tc, 8);
        bm.setCurrentRound(10);

        tok.mint(address(this), 1000 ether);
        tok.approve(address(br), 1000 ether);
        uint256 id = br.seedWinningTicket(tc, 1000 ether, 9);

        // Use the fixed path via a direct broker-style call
        tok.mint(address(this), 1000 ether);
        // Manually: transfer fees to bonding and call fixed update
        // (control reuses BondingManager.updateTranscoderWithFeesFixed)
        // First, reclaim ticket setup by calling fixed path as broker would:
        // Seed bonding with fees and call fixed.
        vm.prank(address(br));
        // Need fees on bonding first
        tok.transfer(address(bm), 1000 ether);
        vm.prank(address(br));
        bm.updateTranscoderWithFeesFixed(tc, 1000 ether);

        assertEq(tok.balanceOf(tc), 1000 ether, "fixed path pays transcoder");
        (uint256 lastReward, uint256 cumFees, ) = bm.transcoders(tc);
        assertEq(lastReward, 10, "lastRewardRound advanced");
        // 10% treasury cut of 1000 = 100; cumulativeFees = 900
        assertEq(cumFees, 900 ether, "precise 10% treasury cut applied");
        id; // silence
    }

    function test_underflow_DoS_loses_winning_ticket() public {
        exp.run();

        emit log_named_uint("ticket fees locked (FEE)", exp.brokerEnd());
        emit log_named_uint("transcoder paid", exp.transcoderPaid());

        assertTrue(exp.redeemReverted(), "redeem must underflow-revert");
        assertTrue(exp.ticketExpired(), "ticket expires unredeemed");
        assertEq(exp.transcoderPaid(), 0, "transcoder got nothing");
        assertEq(exp.brokerEnd(), 1000 ether, "1000 FEE stuck in broker");
    }
}
