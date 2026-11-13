// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  UsualSP — Cantina Usual phase 2, October 2024.
    Vested usualS is the staking balance and earns rewards. claimOriginalAllocation
    transfers that balance without _updateReward. balanceOf becomes 0, claimReward
    reverts on InsufficientUsualSAllocation, and the 100 reward tokens stay in
    the staking contract. The control snapshots rewards first and pays all 100.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory sym) {
        symbol = sym;
    }

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

error InsufficientUsualSAllocation();
error NotAuthorized();
error AlreadyClaimed();

contract UsualSP {
    Token public usualS;
    Token public usualToken;
    uint256 public rewardPerTokenStored;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public originalAllocation;
    mapping(address => uint256) public originalClaimed;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(Token _usualS, Token _usualToken) {
        usualS = _usualS;
        usualToken = _usualToken;
    }

    function seed(address user, uint256 vested, uint256 rewardPerToken) external {
        balanceOf[user] = vested;
        totalSupply = vested;
        originalAllocation[user] = vested;
        rewardPerTokenStored = rewardPerToken;
        usualS.mint(address(this), vested);
    }

    function earned(address user) public view returns (uint256) {
        return (balanceOf[user] * (rewardPerTokenStored - userRewardPerTokenPaid[user])) / 1e24 + rewards[user];
    }

    function _updateReward(address user) internal {
        rewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    function _available(address user) internal view returns (uint256) {
        return originalAllocation[user] - originalClaimed[user];
    }

    function claimOriginalAllocation() external {
        if (originalAllocation[msg.sender] == 0) revert NotAuthorized();
        uint256 amount = _available(msg.sender);
        if (amount == 0) revert AlreadyClaimed();
        originalClaimed[msg.sender] += amount;
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        // @> VULN: staking balance is cleared here with no _updateReward, so the accrued reward is never snapshotted
        require(usualS.transfer(msg.sender, amount), "usualS");
    }

    function claimReward() external returns (uint256) {
        if (balanceOf[msg.sender] == 0) revert InsufficientUsualSAllocation();
        _updateReward(msg.sender);
        uint256 amount = rewards[msg.sender];
        rewards[msg.sender] = 0;
        require(usualToken.transfer(msg.sender, amount), "reward");
        return amount;
    }
}

contract UsualSPFixed {
    Token public usualS;
    Token public usualToken;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public originalAllocation;
    mapping(address => uint256) public originalClaimed;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    constructor(Token _usualS, Token _usualToken) {
        usualS = _usualS;
        usualToken = _usualToken;
    }

    function seed(address user, uint256 vested, uint256 rewardPerToken) external {
        balanceOf[user] = vested;
        originalAllocation[user] = vested;
        rewardPerTokenStored = rewardPerToken;
        usualS.mint(address(this), vested);
    }

    function earned(address user) public view returns (uint256) {
        return (balanceOf[user] * (rewardPerTokenStored - userRewardPerTokenPaid[user])) / 1e24 + rewards[user];
    }

    function _updateReward(address user) internal {
        rewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    function claimOriginalAllocation() external {
        _updateReward(msg.sender);
        uint256 amount = originalAllocation[msg.sender] - originalClaimed[msg.sender];
        originalClaimed[msg.sender] += amount;
        balanceOf[msg.sender] -= amount;
        require(usualS.transfer(msg.sender, amount), "usualS");
    }

    function claimReward() external returns (uint256) {
        _updateReward(msg.sender);
        uint256 amount = rewards[msg.sender];
        rewards[msg.sender] = 0;
        require(usualToken.transfer(msg.sender, amount), "reward");
        return amount;
    }
}

contract Exploit {
    uint256 public constant VESTED = 100 ether;
    uint256 public constant REWARD = 100 ether;

    Token public usualS;
    Token public usualToken;
    UsualSP public stake;
    uint256 public owedBefore;
    bool public claimReverted;
    uint256 public stuck;

    constructor() {
        usualS = new Token("sUSUAL");
        usualToken = new Token("USUAL");
        stake = new UsualSP(usualS, usualToken);
        stake.seed(address(this), VESTED, 1e24);
    }

    function run() external {
        owedBefore = stake.earned(address(this));
        usualToken.mint(address(stake), REWARD);
        stake.claimOriginalAllocation();
        uint256 earnedAfter = stake.earned(address(this));
        (bool ok,) = address(stake).call(abi.encodeWithSelector(stake.claimReward.selector));
        claimReverted = !ok;
        stuck = usualToken.balanceOf(address(stake));
        require(owedBefore == REWARD, "owed");
        require(usualS.balanceOf(address(this)) == VESTED, "got stake");
        require(stake.balanceOf(address(this)) == 0, "zero stake");
        require(earnedAfter == 0, "wiped");
        require(claimReverted, "claim");
        require(usualToken.balanceOf(address(this)) == 0, "no reward");
        require(stuck == REWARD, "stuck");
    }
}
