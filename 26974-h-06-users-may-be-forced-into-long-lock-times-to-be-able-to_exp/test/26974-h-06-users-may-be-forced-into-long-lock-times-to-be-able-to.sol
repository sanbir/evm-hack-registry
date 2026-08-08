// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Canto (veRWA / FIAT DAO fork) — VotingEscrow.delegate(): a user can be
    forced into extending their lock by up to 5 years just to undelegate back
    to themselves     (Code4rena 2023-08-verwa, #26974, H-06)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. VotingEscrow
    is a near-verbatim reduction of the audited contract (only OpenZeppelin's
    ReentrancyGuard is replaced by a one-line inline guard — the vulnerable
    control-flow, including the blamed `require(toLocked.end >= fromLocked.end,
    ...)` line, is untouched).

    Bob and Dave both lock CANTO at the SAME instant, so both get the SAME
    5-year unlock time (VotingEscrow's lock duration is fixed and always reset
    to "now + 5 years" on every action — there is no way to get two DIFFERENT
    unlock times without real elapsed time between two createLock calls, and a
    cheatcode-free, single-timestamp `run()` cannot itself advance calendar
    time between calls). To reproduce Dave locking "one epoch later than Bob" —
    the exact scenario the finding describes — this file's Exploit has Dave
    createLock normally and then bumps ONLY `locked[dave].end` by one WEEK via
    a single direct storage write, done BEFORE `run()` executes (the
    Playground's `setup.steps`; the registry's outer test does the identical
    thing with a real `vm.store` call). Every effect inside `run()` itself —
    Bob delegating to Dave, and then being unable to undelegate back to himself
    without extending his own lock — is produced by VotingEscrow's unmodified
    delegate() logic executing normally.
//////////////////////////////////////////////////////////////////////////*/

/// @title  VotingEscrow
/// @notice VERBATIM reduction of src/VotingEscrow.sol from the audited repo
///         (code-423n4/2023-08-verwa @ a693b4d). Only OpenZeppelin's
///         ReentrancyGuard is replaced by a one-line inline guard; every
///         function body, state layout (needed so the storage-slot math in
///         the outer test stays correct), and the vulnerable control-flow are
///         unchanged.
contract VotingEscrow {
    event Deposit(address indexed provider, uint256 value, uint256 locktime, LockAction indexed action, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, LockAction indexed action, uint256 ts);

    string public name; // slot 0
    string public symbol; // slot 1
    uint256 public decimals = 18; // slot 2

    uint256 public constant WEEK = 7 days;
    uint256 public constant LOCKTIME = 1825 days;
    uint256 public constant MULTIPLIER = 10 ** 18;

    uint256 public globalEpoch; // slot 3
    Point[1000000000000000000] public pointHistory; // slot 4
    // NOTE on storage layout: `pointHistory` above is a FIXED-size array of a
    // 3-slot struct (Point packs {bias,slope} into 1 slot, plus separate ts and
    // blk slots) with length 1e18, so it reserves 3e18 CONTIGUOUS slots before
    // the next variable gets assigned a slot. That pushes every mapping below
    // to slot (4 + 3e18 + i), not slot (5 + i) — see the outer test's
    // LOCKED_BASE_SLOT constant for the exact derivation used by `vm.store`.
    mapping(address => Point[1000000000]) public userPointHistory; // slot 4+3e18
    mapping(address => uint256) public userPointEpoch; // slot 4+3e18+1
    mapping(uint256 => int128) public slopeChanges; // slot 4+3e18+2
    mapping(address => LockedBalance) public locked; // slot 4+3e18+3 = 3e18+7: [0]=amount,[1]=end,[2]=delegated,[3]=delegatee

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
        int128 delegated;
        address delegatee;
    }

    enum LockAction {
        CREATE,
        INCREASE_AMOUNT,
        INCREASE_AMOUNT_AND_DELEGATION,
        INCREASE_TIME,
        WITHDRAW,
        QUIT,
        DELEGATE,
        UNDELEGATE
    }

    bool private _entered;

    modifier nonReentrant() {
        require(!_entered, "ReentrancyGuard: reentrant call");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(string memory _name, string memory _symbol) {
        pointHistory[0] = Point({bias: int128(0), slope: int128(0), ts: block.timestamp, blk: block.number});
        name = _name;
        symbol = _symbol;
    }

    function lockEnd(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    function _checkpoint(address _addr, LockedBalance memory _oldLocked, LockedBalance memory _newLocked) internal {
        Point memory userOldPoint;
        Point memory userNewPoint;
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 epoch = globalEpoch;

        if (_addr != address(0)) {
            if (_oldLocked.end > block.timestamp && _oldLocked.delegated > 0) {
                userOldPoint.slope = _oldLocked.delegated / int128(int256(LOCKTIME));
                userOldPoint.bias = userOldPoint.slope * int128(int256(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp && _newLocked.delegated > 0) {
                userNewPoint.slope = _newLocked.delegated / int128(int256(LOCKTIME));
                userNewPoint.bias = userNewPoint.slope * int128(int256(_newLocked.end - block.timestamp));
            }

            uint256 uEpoch = userPointEpoch[_addr];
            if (uEpoch == 0) {
                userPointHistory[_addr][uEpoch + 1] = userOldPoint;
            }

            userPointEpoch[_addr] = uEpoch + 1;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[_addr][uEpoch + 1] = userNewPoint;

            oldSlopeDelta = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    newSlopeDelta = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory lastPoint = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number});
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;

        Point memory initialLastPoint = Point({bias: 0, slope: 0, ts: lastPoint.ts, blk: lastPoint.blk});
        uint256 blockSlope = 0;
        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }

        uint256 iterativeTime = _floorToWeek(lastCheckpoint);
        for (uint256 i = 0; i < 255; i++) {
            iterativeTime = iterativeTime + WEEK;
            int128 dSlope = 0;
            if (iterativeTime > block.timestamp) {
                iterativeTime = block.timestamp;
            } else {
                dSlope = slopeChanges[iterativeTime];
            }
            int128 biasDelta = lastPoint.slope * int128(int256((iterativeTime - lastCheckpoint)));
            lastPoint.bias = lastPoint.bias - biasDelta;
            lastPoint.slope = lastPoint.slope + dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckpoint = iterativeTime;
            lastPoint.ts = iterativeTime;
            lastPoint.blk = initialLastPoint.blk + (blockSlope * (iterativeTime - initialLastPoint.ts)) / MULTIPLIER;

            epoch = epoch + 1;
            if (iterativeTime == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[epoch] = lastPoint;
            }
        }

        globalEpoch = epoch;

        if (_addr != address(0)) {
            lastPoint.slope = lastPoint.slope + userNewPoint.slope - userOldPoint.slope;
            lastPoint.bias = lastPoint.bias + userNewPoint.bias - userOldPoint.bias;
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        pointHistory[epoch] = lastPoint;

        if (_addr != address(0)) {
            if (_oldLocked.end > block.timestamp) {
                oldSlopeDelta = oldSlopeDelta + userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldSlopeDelta = oldSlopeDelta - userNewPoint.slope;
                }
                slopeChanges[_oldLocked.end] = oldSlopeDelta;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newSlopeDelta = newSlopeDelta - userNewPoint.slope;
                    slopeChanges[_newLocked.end] = newSlopeDelta;
                }
            }
        }
    }

    function createLock(uint256 _value) external payable nonReentrant {
        uint256 unlock_time = _floorToWeek(block.timestamp + LOCKTIME);
        LockedBalance memory locked_ = locked[msg.sender];
        require(_value > 0, "Only non zero amount");
        require(msg.value == _value, "Invalid value");
        require(locked_.amount == 0, "Lock exists");
        locked_.amount += int128(int256(_value));
        locked_.end = unlock_time;
        locked_.delegated += int128(int256(_value));
        locked_.delegatee = msg.sender;
        locked[msg.sender] = locked_;
        _checkpoint(msg.sender, LockedBalance(0, 0, 0, address(0)), locked_);

        emit Deposit(msg.sender, _value, unlock_time, LockAction.CREATE, block.timestamp);
    }

    function withdraw() external nonReentrant {
        LockedBalance memory locked_ = locked[msg.sender];
        require(locked_.amount > 0, "No lock");
        require(locked_.end <= block.timestamp, "Lock not expired");
        require(locked_.delegatee == msg.sender, "Lock delegated");
        uint256 amountToSend = uint256(uint128(locked_.amount));
        LockedBalance memory newLocked = _copyLock(locked_);
        newLocked.amount = 0;
        newLocked.end = 0;
        newLocked.delegated -= int128(int256(amountToSend));
        newLocked.delegatee = address(0);
        locked[msg.sender] = newLocked;
        newLocked.delegated = 0;
        _checkpoint(msg.sender, locked_, newLocked);
        (bool success,) = msg.sender.call{value: amountToSend}("");
        require(success, "Failed to send CANTO");
        emit Withdraw(msg.sender, amountToSend, LockAction.WITHDRAW, block.timestamp);
    }

    /// @notice Delegate voting power / lock ownership to another address (or
    ///         back to `msg.sender` to undelegate).
    /// @dev @> VULN: the "only delegate to a longer (or equal) lock" check
    ///      below is meant to stop a lock's voting power from outliving its
    ///      backing CANTO, but it also blocks UNDELEGATING back to yourself
    ///      whenever your own lock happens to be even ONE SECOND shorter than
    ///      the delegatee's — which is the normal case whenever two locks were
    ///      created at different times, since VotingEscrow always resets the
    ///      lock duration to a fixed 5 years. The only way around it is to
    ///      extend your own lock (via increaseAmount/createLock semantics) by
    ///      up to the full 5-year LOCKTIME, just to get your own `end` back in
    ///      line — even if you only wanted your voting power back.
    ///      FIX (per the finding): `require(toLocked.end >= locked_.end, ...)`
    ///      — compare against the CALLER's own current lock, not the lock the
    ///      caller is moving power FROM.
    function delegate(address _addr) external nonReentrant {
        LockedBalance memory locked_ = locked[msg.sender];
        require(locked_.amount > 0, "No lock");
        require(locked_.delegatee != _addr, "Already delegated");
        int128 value = locked_.amount;
        address delegatee = locked_.delegatee;
        LockedBalance memory fromLocked;
        LockedBalance memory toLocked;
        locked_.delegatee = _addr;
        if (delegatee == msg.sender) {
            fromLocked = locked_;
            toLocked = locked[_addr];
        } else if (_addr == msg.sender) {
            fromLocked = locked[delegatee];
            toLocked = locked_;
        } else {
            fromLocked = locked[delegatee];
            toLocked = locked[_addr];
            locked[msg.sender] = locked_;
        }
        require(toLocked.amount > 0, "Delegatee has no lock");
        require(toLocked.end > block.timestamp, "Delegatee lock expired");
        require(toLocked.end >= fromLocked.end, "Only delegate to longer lock"); // @> VULN
        _delegate(delegatee, fromLocked, value, LockAction.UNDELEGATE);
        _delegate(_addr, toLocked, value, LockAction.DELEGATE);
    }

    function _delegate(address addr, LockedBalance memory _locked, int128 value, LockAction action) internal {
        LockedBalance memory newLocked = _copyLock(_locked);
        if (action == LockAction.DELEGATE) {
            newLocked.delegated += value;
            emit Deposit(addr, uint256(int256(value)), newLocked.end, action, block.timestamp);
        } else {
            newLocked.delegated -= value;
            emit Withdraw(addr, uint256(int256(value)), action, block.timestamp);
        }
        locked[addr] = newLocked;
        if (newLocked.amount > 0) {
            _checkpoint(addr, _locked, newLocked);
        }
    }

    function _copyLock(LockedBalance memory _locked) internal pure returns (LockedBalance memory) {
        return LockedBalance({
            amount: _locked.amount,
            end: _locked.end,
            delegatee: _locked.delegatee,
            delegated: _locked.delegated
        });
    }

    function _floorToWeek(uint256 _t) internal pure returns (uint256) {
        return (_t / WEEK) * WEEK;
    }

    function balanceOf(address _owner) public view returns (uint256) {
        uint256 epoch = userPointEpoch[_owner];
        if (epoch == 0) {
            return 0;
        }
        Point memory lastPoint = userPointHistory[_owner][epoch];
        lastPoint.bias = lastPoint.bias - (lastPoint.slope * int128(int256(block.timestamp - lastPoint.ts)));
        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(uint128(lastPoint.bias));
    }
}

/// @dev Orchestrator. Bob and Dave both createLock at the SAME instant (the
///      only option inside a cheatcode-free, single-timestamp run — see file
///      header), so both start with an IDENTICAL 5-year unlock time. To
///      reproduce Dave locking "one epoch later" — the exact precondition the
///      finding describes — `locked[dave].end` is bumped by exactly one WEEK
///      directly in storage BEFORE `run()` (the Playground's `setup.steps` /
///      this file's outer Foundry test `vm.store`). Every effect inside
///      `run()` itself is produced by VotingEscrow's unmodified delegate()
///      logic executing normally.
contract Exploit {
    VotingEscrow public ve; // CREATE nonce 1
    Bob public bob; // CREATE nonce 2
    Dave public dave; // CREATE nonce 3

    uint256 public constant LOCK_AMT = 1 ether;

    constructor() {
        ve = new VotingEscrow("veCANTO", "veCANTO"); // CREATE nonce 1
        bob = new Bob(); // CREATE nonce 2
        dave = new Dave(); // CREATE nonce 3
    }

    receive() external payable {}

    /// @notice Funds and locks Bob and Dave at the SAME instant (so both start
    ///         with an IDENTICAL 5-year unlock time). Called from `setup.steps`
    ///         (Playground) / the outer Foundry test, AFTER deploy but BEFORE
    ///         the traced `run()` call — this contract must already hold
    ///         `2 * LOCK_AMT` native CANTO (funded by an earlier setup step /
    ///         `vm.deal`) for the two `lock{value: ...}` calls below to work.
    function seed() external {
        bob.lock{value: LOCK_AMT}(ve, LOCK_AMT);
        dave.lock{value: LOCK_AMT}(ve, LOCK_AMT);
        // At this point locked[bob].end == locked[dave].end exactly (both
        // locked in this same call). The precondition-seeding step bumps
        // locked[dave].end by one WEEK, still before run() executes.
    }

    /// @notice Called AFTER `locked[dave].end` has been bumped by one WEEK,
    ///         representing Dave having locked one epoch later than Bob.
    function run() external {
        uint256 bobEnd = ve.lockEnd(address(bob));
        uint256 daveEnd = ve.lockEnd(address(dave));
        require(daveEnd > bobEnd, "precondition not planted: dave must lock later than bob");

        // Bob delegates his voting power to Dave (allowed: Dave's lock is
        // longer, satisfying "Only delegate to longer lock").
        bob.delegateTo(ve, address(dave));
        (,,, address delegateeAfterDelegate) = ve.locked(address(bob));
        require(delegateeAfterDelegate == address(dave), "bob should now be delegated to dave");

        // HARM: Bob tries to undelegate back to himself — and cannot, purely
        // because his own lock is one epoch shorter than Dave's, even though
        // Bob never asked to extend anything.
        bool undelegateSucceeded = bob.tryUndelegate(ve);
        require(!undelegateSucceeded, "expected undelegate-to-self to revert (bug not present)");

        (,,, address delegateeAfterFailedUndelegate) = ve.locked(address(bob));
        require(delegateeAfterFailedUndelegate == address(dave), "bob's voting power is still stuck with dave");
    }
}

/// @dev Victim: locks CANTO, delegates to another lock, and later tries to
///     undelegate back to itself.
contract Bob {
    function lock(VotingEscrow ve, uint256 amount) external payable {
        ve.createLock{value: amount}(amount);
    }

    function delegateTo(VotingEscrow ve, address to) external {
        ve.delegate(to);
    }

    /// @return true if `delegate(self)` succeeded, false if it reverted.
    function tryUndelegate(VotingEscrow ve) external returns (bool) {
        (bool ok,) = address(ve).call(abi.encodeWithSelector(VotingEscrow.delegate.selector, address(this)));
        return ok;
    }
}

/// @dev The delegatee: locks CANTO at the same instant as Bob (its `end` is
///      then bumped by one WEEK before `run()` — see Exploit's header).
contract Dave {
    function lock(VotingEscrow ve, uint256 amount) external payable {
        ve.createLock{value: amount}(amount);
    }
}
