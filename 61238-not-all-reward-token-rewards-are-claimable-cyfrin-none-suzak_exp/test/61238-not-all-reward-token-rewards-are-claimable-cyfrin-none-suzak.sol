// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Suzaku Rewards.claimRewards — the claim cursor is not keyed by token
    (Cyfrin / 0kage, #61238, July 2025).
    SYNTHETIC, cheatcode-free. No vm.warp: the middleware epoch counter is the
    same value the real contract reads from time, set inside one transaction.
    lastEpochClaimedStaker is keyed only by the staker. Claiming token A for
    epoch 1 marks that epoch claimed for every token. Token B of N = 1,000
    stays in the contract. Token A of 100 is paid. Control keys the cursor
    by (staker, token) and pays both. */

contract Token {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Middleware {
    uint48 public currentEpoch;

    function setEpoch(uint48 epoch) external {
        currentEpoch = epoch;
    }

    function getCurrentEpoch() public view returns (uint48) {
        return currentEpoch;
    }
}

contract Rewards {
    Middleware public middleware;
    mapping(address => uint48) public lastEpochClaimedStaker;
    mapping(address => mapping(uint48 => mapping(address => uint256))) public rewardsOf;

    error AlreadyClaimedForLatestEpoch(address user, uint48 last);
    error NoRewardsToClaim(address user);

    constructor(Middleware _middleware) {
        middleware = _middleware;
    }

    function setReward(address rewardsToken, uint48 epoch, address staker, uint256 amount) external {
        rewardsOf[rewardsToken][epoch][staker] = amount;
    }

    function claimRewards(address rewardsToken, address recipient) external {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimed = lastEpochClaimedStaker[msg.sender];
        if (lastClaimed >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimed);
        }

        uint256 totalRewards = 0;
        for (uint48 epoch = lastClaimed + 1; epoch < currentEpoch; ++epoch) {
            uint256 amount = rewardsOf[rewardsToken][epoch][msg.sender];
            if (amount == 0) continue;
            totalRewards += amount;
        }
        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        // FIX: key lastEpochClaimedStaker by rewardsToken as well as the staker
        // @> VULN: one cursor covers every reward token, so claiming A marks B claimed
        lastEpochClaimedStaker[msg.sender] = currentEpoch - 1;
        Token(rewardsToken).transfer(recipient, totalRewards);
    }
}

contract RewardsFixed {
    Middleware public middleware;
    mapping(address => mapping(address => uint48)) public lastEpochClaimedStaker;
    mapping(address => mapping(uint48 => mapping(address => uint256))) public rewardsOf;

    error AlreadyClaimedForLatestEpoch(address user, uint48 last);
    error NoRewardsToClaim(address user);

    constructor(Middleware _middleware) {
        middleware = _middleware;
    }

    function setReward(address rewardsToken, uint48 epoch, address staker, uint256 amount) external {
        rewardsOf[rewardsToken][epoch][staker] = amount;
    }

    function claimRewards(address rewardsToken, address recipient) external {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimed = lastEpochClaimedStaker[msg.sender][rewardsToken];
        if (lastClaimed >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimed);
        }

        uint256 totalRewards = 0;
        for (uint48 epoch = lastClaimed + 1; epoch < currentEpoch; ++epoch) {
            uint256 amount = rewardsOf[rewardsToken][epoch][msg.sender];
            if (amount == 0) continue;
            totalRewards += amount;
        }
        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        lastEpochClaimedStaker[msg.sender][rewardsToken] = currentEpoch - 1;
        Token(rewardsToken).transfer(recipient, totalRewards);
    }
}

contract Exploit {
    uint256 public constant AMOUNT_A = 100 ether;
    uint256 public constant N = 1_000 ether;

    Token public tokenA;
    Token public tokenB;
    Middleware public middleware;
    Rewards public rewards;
    uint48 public cursorAfterA;
    bool public tokenBBlocked;
    uint256 public stuckB;
    uint256 public paidA;

    constructor() {
        tokenA = new Token();
        tokenB = new Token();
        middleware = new Middleware();
        rewards = new Rewards(middleware);
    }

    function run() external {
        middleware.setEpoch(2);
        tokenA.mint(address(rewards), AMOUNT_A);
        tokenB.mint(address(rewards), N);
        rewards.setReward(address(tokenA), 1, address(this), AMOUNT_A);
        rewards.setReward(address(tokenB), 1, address(this), N);

        rewards.claimRewards(address(tokenA), msg.sender);
        cursorAfterA = rewards.lastEpochClaimedStaker(address(this));
        require(cursorAfterA == 1, "cursor advanced for every token");
        paidA = tokenA.balanceOf(msg.sender);
        require(paidA == AMOUNT_A, "token A was not paid");

        try rewards.claimRewards(address(tokenB), msg.sender) {
            tokenBBlocked = false;
        } catch {
            tokenBBlocked = true;
        }
        require(tokenBBlocked, "token B was still claimable");
        stuckB = tokenB.balanceOf(address(rewards));
        require(stuckB == N, "token B was not stuck");
        require(tokenB.balanceOf(msg.sender) == 0, "token B was paid");
    }
}
