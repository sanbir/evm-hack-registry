// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Synthetic, self-contained reproduction of AuditVault finding 59358:
// "Loss of Pending Reward when Unstaking" (Quantstamp / Zero Staking).
//
// StakingERC20.unstake(amount, exit=true): when the user unstakes their FULL
// balance, the code `delete stakers[msg.sender]` wipes `staker.owedRewards`
// even though owedRewards > 0, so the user permanently loses all pending rewards.
//
// Everything below (tokens, staking manager) is a FAITHFUL MINIMAL double.
// No cheatcodes, no forge-std import in this file.

// -----------------------------------------------------------------------------
// Minimal ERC20 double (also used as the harm MARKER token).
// -----------------------------------------------------------------------------
contract MiniToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// -----------------------------------------------------------------------------
// Vulnerable staking manager (minimal double of StakingERC20.sol).
// -----------------------------------------------------------------------------
contract StakingERC20 {
    struct Staker {
        uint256 amountStaked;
        uint256 owedRewards;
        uint256 lastUpdated;
    }

    mapping(address => Staker) public stakers;

    MiniToken public immutable stakingToken;
    MiniToken public immutable rewardsToken;
    uint256 public constant rewardPerSecond = 1e18;

    // Simulated protocol clock (part of the double; replaces block.timestamp so
    // the reproduction needs no cheatcodes).
    uint256 public clock;

    constructor(MiniToken _stakingToken, MiniToken _rewardsToken) {
        stakingToken = _stakingToken;
        rewardsToken = _rewardsToken;
    }

    function warp(uint256 delta) external {
        clock += delta;
    }

    function _accrue(address user) internal {
        Staker storage s = stakers[user];
        if (s.amountStaked > 0) {
            s.owedRewards += (clock - s.lastUpdated) * rewardPerSecond;
        }
        s.lastUpdated = clock;
    }

    function pendingRewards(address user) public view returns (uint256) {
        Staker storage s = stakers[user];
        uint256 pending = s.owedRewards;
        if (s.amountStaked > 0) {
            pending += (clock - s.lastUpdated) * rewardPerSecond;
        }
        return pending;
    }

    function stake(uint256 amount) external {
        _accrue(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        stakers[msg.sender].amountStaked += amount;
    }

    // VULNERABLE unstake: full-balance exit deletes the Staker struct, wiping
    // owedRewards without ever paying them out.
    function unstake(uint256 amount, bool exit) external {
        Staker storage staker = stakers[msg.sender];
        require(staker.amountStaked >= amount, "too much");

        _accrue(msg.sender);

        // Return the staked principal to the user.
        stakingToken.transfer(msg.sender, amount);

        if (staker.amountStaked - amount == 0) {
            if (!exit) {
                // Non-exit full unstake pays out owed rewards first.
                uint256 owed = staker.owedRewards;
                if (owed > 0) rewardsToken.transfer(msg.sender, owed);
            }
            delete stakers[msg.sender]; // @> wipes owedRewards even when exit=true and owedRewards>0
        } else {
            staker.amountStaked -= amount;
        }
    }
}

// -----------------------------------------------------------------------------
// Fixed staking manager: pays owedRewards before deleting the Staker struct.
// -----------------------------------------------------------------------------
contract StakingERC20Fixed {
    struct Staker {
        uint256 amountStaked;
        uint256 owedRewards;
        uint256 lastUpdated;
    }

    mapping(address => Staker) public stakers;

    MiniToken public immutable stakingToken;
    MiniToken public immutable rewardsToken;
    uint256 public constant rewardPerSecond = 1e18;
    uint256 public clock;

    constructor(MiniToken _stakingToken, MiniToken _rewardsToken) {
        stakingToken = _stakingToken;
        rewardsToken = _rewardsToken;
    }

    function warp(uint256 delta) external {
        clock += delta;
    }

    function _accrue(address user) internal {
        Staker storage s = stakers[user];
        if (s.amountStaked > 0) {
            s.owedRewards += (clock - s.lastUpdated) * rewardPerSecond;
        }
        s.lastUpdated = clock;
    }

    function pendingRewards(address user) public view returns (uint256) {
        Staker storage s = stakers[user];
        uint256 pending = s.owedRewards;
        if (s.amountStaked > 0) {
            pending += (clock - s.lastUpdated) * rewardPerSecond;
        }
        return pending;
    }

    function stake(uint256 amount) external {
        _accrue(msg.sender);
        stakingToken.transferFrom(msg.sender, address(this), amount);
        stakers[msg.sender].amountStaked += amount;
    }

    function unstake(uint256 amount, bool exit) external {
        Staker storage staker = stakers[msg.sender];
        require(staker.amountStaked >= amount, "too much");

        _accrue(msg.sender);
        stakingToken.transfer(msg.sender, amount);

        if (staker.amountStaked - amount == 0) {
            // FIX: always pay out owed rewards before deleting the struct.
            uint256 owed = staker.owedRewards;
            if (owed > 0) rewardsToken.transfer(msg.sender, owed);
            delete stakers[msg.sender];
        } else {
            staker.amountStaked -= amount;
        }
    }
}

// -----------------------------------------------------------------------------
// Exploit / harm driver.
// -----------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public lostRewards;         // owed rewards the user should have received
    uint256 public rewardsReceived;     // rewards actually received by the user
    uint256 public stakedReturned;      // staked principal returned to the user

    function run() external payable {
        // --- Create EVERY helper contract up front, in a fixed order ---
        MiniToken stakingToken = new MiniToken("STAKE");   // nonce 1
        MiniToken rewardsToken = new MiniToken("REWARD");  // nonce 2
        StakingERC20 staking = new StakingERC20(stakingToken, rewardsToken); // nonce 3
        MiniToken marker = new MiniToken("LOST-REWARDS");  // nonce 4 (LAST new)

        // --- Preconditions: this contract is the honest staker ---
        uint256 stakeAmount = 1_000e18;
        stakingToken.mint(address(this), stakeAmount);
        stakingToken.approve(address(staking), stakeAmount);

        // Fund the staking manager with reward tokens (so payout is possible).
        rewardsToken.mint(address(staking), 1_000_000e18);

        // Stake full amount.
        staking.stake(stakeAmount);

        // Time passes -> rewards accrue.
        staking.warp(100); // 100 * 1e18 = 100e18 pending rewards

        // Snapshot the rewards the user is owed right before unstaking.
        lostRewards = staking.pendingRewards(address(this));

        // --- Execute the bug: full unstake with exit = true ---
        staking.unstake(stakeAmount, true);

        // Measure outcome.
        rewardsReceived = rewardsToken.balanceOf(address(this));
        stakedReturned = stakingToken.balanceOf(address(this));

        // Non-fund self-loss harm: mint a MARKER equal to the lost rewards to SINK.
        marker.mint(SINK, lostRewards);
    }
}
