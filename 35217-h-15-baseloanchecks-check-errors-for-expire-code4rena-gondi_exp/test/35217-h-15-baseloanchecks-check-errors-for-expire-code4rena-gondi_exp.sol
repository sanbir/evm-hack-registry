// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Auction,
    Exploit,
    MultiSourceLoan,
    PrincipalToken,
    Terms
} from "./35217-h-15-baseloanchecks-check-errors-for-expire-code4rena-gondi.sol";

/// Fix: expiry is `<= block.timestamp`, so the exact expiry second is already expired.
contract GuardedLoan {
    PrincipalToken public immutable token;
    Auction public immutable auction;
    mapping(uint256 => bytes32) public loanHash;

    constructor(PrincipalToken _token, Auction _auction) {
        token = _token;
        auction = _auction;
    }

    function hashLoan(MultiSourceLoan.Loan memory loan) public pure returns (bytes32) {
        return keccak256(abi.encode(loan.id, loan.borrower, loan.startTime, loan.duration, loan.tokenId));
    }

    function seed(MultiSourceLoan.Loan memory loan) external {
        loanHash[loan.id] = hashLoan(loan);
    }

    function liquidate(MultiSourceLoan.Loan calldata loan) external {
        require(loanHash[loan.id] == hashLoan(loan), "loan");
        uint256 expirationTime = loan.startTime + loan.duration;
        if (expirationTime > block.timestamp) revert("not due");
        token.transferFrom(msg.sender, address(auction), Terms.BID);
        auction.open(loan.id, Terms.BID);
    }

    function addNewTranche(MultiSourceLoan.Loan memory loan) external view {
        require(loanHash[loan.id] == hashLoan(loan), "loan");
        if (loan.startTime + loan.duration <= block.timestamp) revert("expired");
    }

    function settle(uint256 loanId) external {
        require(loanHash[loanId] != bytes32(0), "cleared");
        auction.pay(Terms.LENDER);
        delete loanHash[loanId];
    }
}

contract Finding35217Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant AUCTION = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant LOAN = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_exact_expiry_locks_the_bid() public {
        assertEq(block.timestamp, 1, "clock");
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.token()), TOKEN, "token");
        assertEq(address(e.auction()), AUCTION, "auction");
        assertEq(address(e.loan()), LOAN, "loan");

        vm.prank(ATTACKER);
        e.run();

        assertEq(e.token().balanceOf(AUCTION), Terms.BID, "locked");
        assertEq(e.token().balanceOf(Terms.LENDER), 0, "lender");
        assertTrue(e.settleFailed(), "settle");
        assertTrue(e.loan().mutated(), "mutated");
        assertEq(e.loan().loanHash(Terms.LOAN_ID), bytes32(0), "cleared");
    }

    function test_control_rejects_exact_expiry_and_settles() public {
        assertEq(block.timestamp, 1, "clock");
        PrincipalToken token = new PrincipalToken();
        Auction auction = new Auction(token);
        GuardedLoan guarded = new GuardedLoan(token, auction);
        MultiSourceLoan.Loan memory openLoan = MultiSourceLoan.Loan({
            id: Terms.LOAN_ID,
            borrower: Terms.BORROWER,
            startTime: Terms.START,
            duration: Terms.DURATION,
            tokenId: Terms.TOKEN_ID
        });
        guarded.seed(openLoan);
        token.mintAndApprove(address(this), address(guarded), Terms.BID);
        guarded.liquidate(openLoan);

        vm.expectRevert(bytes("expired"));
        guarded.addNewTranche(openLoan);

        assertEq(guarded.loanHash(Terms.LOAN_ID), guarded.hashLoan(openLoan), "hash");
        guarded.settle(Terms.LOAN_ID);
        assertEq(token.balanceOf(address(auction)), 0, "auction");
        assertEq(token.balanceOf(Terms.LENDER), Terms.BID, "paid");
    }
}
