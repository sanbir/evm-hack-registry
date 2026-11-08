// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Suzaku Rewards.claimOperatorFee — intermediate epochs become unclaimable
    (Cyfrin / 0kage, #61234, July 2025).
    SYNTHETIC, cheatcode-free. No vm.warp: the middleware epoch counter is the
    same value the real contract reads from time, advanced between the steps
    of the report's sequence inside one transaction.
    Claim sets lastEpochClaimedOperator = currentEpoch - 1 even for epochs
    that were not distributed yet. Epoch-2 rewards of N = 1,000 stay in the
    contract and a later claim never visits that epoch.
    Control advances the cursor only through epochs that were actually paid,
    and the second claim pays N. */

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

    function getCurrentEpoch() external view returns (uint48) {
        return currentEpoch;
    }
}

contract Rewards {
    uint256 public constant BPS = 10_000;

    Middleware public immutable middleware;
    mapping(address => mapping(address => uint48)) public lastEpochClaimedOperator;
    mapping(uint48 => uint256) public epochRewards;
    mapping(uint48 => mapping(address => uint256)) public operatorShares;

    error NoRewardsToClaim(address user);
    error AlreadyClaimedForLatestEpoch(address user, uint48 last);

    constructor(Middleware _middleware) {
        middleware = _middleware;
    }

    function distributeRewards(uint48 epoch, address operator, uint256 amount, uint256 shareBps) external {
        epochRewards[epoch] = amount;
        operatorShares[epoch][operator] = shareBps;
    }

    function claimOperatorFee(address rewardsToken, address recipient) external {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedOperator[msg.sender][rewardsToken];
        if (lastClaimedEpoch >= currentEpoch - 1) {
            revert AlreadyClaimedForLatestEpoch(msg.sender, lastClaimedEpoch);
        }

        uint256 totalRewards = 0;
        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; ++epoch) {
            uint256 rewardsAmount = epochRewards[epoch];
            if (rewardsAmount == 0) continue;
            uint256 share = operatorShares[epoch][msg.sender];
            if (share == 0) continue;
            totalRewards += rewardsAmount * share / BPS;
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        lastEpochClaimedOperator[msg.sender][rewardsToken] = currentEpoch - 1; // @> VULN: skips epochs not yet distributed
        Token(rewardsToken).transfer(recipient, totalRewards);
    }
}

contract RewardsFixed {
    uint256 public constant BPS = 10_000;

    Middleware public immutable middleware;
    mapping(address => mapping(address => uint48)) public lastEpochClaimedOperator;
    mapping(uint48 => uint256) public epochRewards;
    mapping(uint48 => mapping(address => uint256)) public operatorShares;

    error NoRewardsToClaim(address user);

    constructor(Middleware _middleware) {
        middleware = _middleware;
    }

    function distributeRewards(uint48 epoch, address operator, uint256 amount, uint256 shareBps) external {
        epochRewards[epoch] = amount;
        operatorShares[epoch][operator] = shareBps;
    }

    function claimOperatorFee(address rewardsToken, address recipient) external {
        uint48 currentEpoch = middleware.getCurrentEpoch();
        uint48 lastClaimedEpoch = lastEpochClaimedOperator[msg.sender][rewardsToken];
        uint48 newLast = lastClaimedEpoch;
        uint256 totalRewards = 0;

        for (uint48 epoch = lastClaimedEpoch + 1; epoch < currentEpoch; ++epoch) {
            uint256 rewardsAmount = epochRewards[epoch];
            if (rewardsAmount == 0) continue;
            uint256 share = operatorShares[epoch][msg.sender];
            if (share == 0) continue;
            totalRewards += rewardsAmount * share / BPS;
            newLast = epoch;
        }

        if (totalRewards == 0) revert NoRewardsToClaim(msg.sender);
        lastEpochClaimedOperator[msg.sender][rewardsToken] = newLast;
        Token(rewardsToken).transfer(recipient, totalRewards);
    }
}

contract Exploit {
    uint256 public constant EPOCH1 = 100 ether;
    uint256 public constant N = 1_000 ether;

    Token public reward;
    Middleware public middleware;
    Rewards public rewards;
    uint48 public cursorAfterFirstClaim;
    bool public secondClaimBlocked;
    uint256 public stranded;

    constructor() {
        reward = new Token();
        middleware = new Middleware();
        rewards = new Rewards(middleware);
    }

    function run() external {
        reward.mint(address(rewards), EPOCH1 + N);
        middleware.setEpoch(5);
        rewards.distributeRewards(1, address(this), EPOCH1, rewards.BPS());

        rewards.claimOperatorFee(address(reward), msg.sender);
        cursorAfterFirstClaim = rewards.lastEpochClaimedOperator(address(this), address(reward));
        require(cursorAfterFirstClaim == 4, "cursor jumped to current-1");
        require(reward.balanceOf(msg.sender) == EPOCH1, "only epoch 1 was paid");

        rewards.distributeRewards(2, address(this), N, rewards.BPS());
        middleware.setEpoch(9);

        try rewards.claimOperatorFee(address(reward), msg.sender) {
            secondClaimBlocked = false;
        } catch {
            secondClaimBlocked = true;
        }
        require(secondClaimBlocked, "epoch 2 was still claimable");

        stranded = reward.balanceOf(address(rewards));
        require(stranded == N, "epoch 2 rewards not stranded");
        require(reward.balanceOf(msg.sender) == EPOCH1, "epoch 2 was paid");
    }
}
