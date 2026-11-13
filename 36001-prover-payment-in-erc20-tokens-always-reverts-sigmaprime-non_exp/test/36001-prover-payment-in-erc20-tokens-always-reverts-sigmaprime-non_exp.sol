// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeToken,
    Proposer,
    AssignmentHooksFixed,
    Assignment,
    BlockData,
    HookInput
} from "./36001-prover-payment-in-erc20-tokens-always-reverts-sigmaprime-non.sol";

contract Finding36001Test is Test {
    address internal constant PROVER = 0x4444444444444444444444444444444444444444;

    function test_exploit_erc20_payment_reverts_and_fee_stays() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.reverted(), "propose reverted");
        assertEq(e.proverPaid(), 0, "prover unpaid");
        assertEq(e.stuck(), e.FEE(), "100 FEE stayed with the proposer");
        assertEq(e.token().balanceOf(address(e.proposer())), 100 ether, "proposer still holds 100");
        assertEq(e.token().balanceOf(PROVER), 0, "prover balance");
        assertEq(e.token().balanceOf(address(e.taiko())), 0, "taiko holds nothing");
    }

    function test_control_proposer_pays_the_prover() public {
        FeeToken token = new FeeToken();
        Proposer proposer = new Proposer();
        AssignmentHooksFixed hooks = new AssignmentHooksFixed();
        token.mint(address(proposer), 100 ether);
        proposer.approve(token, address(hooks), 100 ether);

        hooks.onProposedBlock(
            Assignment({feeToken: address(token)}),
            BlockData({assignedProver: PROVER}),
            HookInput({tip: 0}),
            address(proposer),
            100 ether
        );

        assertEq(token.balanceOf(PROVER), 100 ether, "control pays 100 to the prover");
        assertEq(token.balanceOf(address(proposer)), 0, "proposer paid the fee");
    }
}
