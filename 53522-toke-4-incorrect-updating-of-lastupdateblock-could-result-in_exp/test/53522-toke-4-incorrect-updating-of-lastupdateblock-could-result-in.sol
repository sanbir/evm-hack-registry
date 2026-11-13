// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Tokemak TOKE-4 (AuditVault 53522). _updateReward writes lastUpdateBlock
   whenever rewardPerTokenStored > 0. A zero stake does not force that
   stored value to 0, so the empty window from block 5 to block 10 is
   skipped. 1500 of rewards are funded, 1000 are paid, 500 stay with no
   claimant. The fixed branch queues that 500 and pays it out. */

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

abstract contract RewarderBase {
    RewardToken public token;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateBlock;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;
    uint256 public queuedRewards;
    uint256 public clock;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerTokenPaid;

    constructor(RewardToken token_) {
        token = token_;
        rewardRate = 100 ether;
        periodFinish = 15;
    }

    function totalSupply() public view returns (uint256) {
        return totalStaked;
    }

    function setClock(uint256 b) external {
        clock = b;
    }

    function lastBlockRewardApplicable() public view returns (uint256) {
        return clock < periodFinish ? clock : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + (lastBlockRewardApplicable() - lastUpdateBlock) * rewardRate * 1e18 / totalSupply();
    }

    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18 + rewards[account];
    }

    function _updateReward(address account) internal virtual;

    function stake(address account, uint256 amount) external {
        _updateReward(account);
        balanceOf[account] += amount;
        totalStaked += amount;
    }

    function withdraw(address account, uint256 amount) external {
        _updateReward(account);
        balanceOf[account] -= amount;
        totalStaked -= amount;
    }

    function getReward(address account) external {
        _updateReward(account);
        uint256 r = rewards[account];
        rewards[account] = 0;
        if (r > 0) {
            require(token.transfer(account, r), "pay");
        }
    }

    function claimQueued(address to) external {
        uint256 q = queuedRewards;
        queuedRewards = 0;
        if (q > 0) {
            require(token.transfer(to, q), "queue");
        }
    }
}

contract Rewarder is RewarderBase {
    event UserRewardUpdated(address account, uint256 earnedRewards, uint256 rewardPerTokenStored, uint256 lastUpdateBlock);

    constructor(RewardToken token_) RewarderBase(token_) {}

    function _updateReward(address account) internal override {
        uint256 earnedRewards = 0;
        rewardPerTokenStored = rewardPerToken();
        // @> VULN: lastUpdateBlock moves whenever rewardPerTokenStored > 0, even if totalSupply() is 0
        if (rewardPerTokenStored > 0) {
            if (account != address(0)) {
                lastUpdateBlock = lastBlockRewardApplicable();
                earnedRewards = earned(account);
                rewards[account] = earnedRewards;
                userRewardPerTokenPaid[account] = rewardPerTokenStored;
            }
        }
        emit UserRewardUpdated(account, earnedRewards, rewardPerTokenStored, lastUpdateBlock);
    }
}

contract RewarderFixed is RewarderBase {
    constructor(RewardToken token_) RewarderBase(token_) {}

    function _updateReward(address account) internal override {
        uint256 earnedRewards = 0;
        rewardPerTokenStored = rewardPerToken();
        if (totalSupply() > 0) {
            if (account != address(0)) {
                lastUpdateBlock = lastBlockRewardApplicable();
                earnedRewards = earned(account);
                rewards[account] = earnedRewards;
                userRewardPerTokenPaid[account] = rewardPerTokenStored;
            }
        } else {
            uint256 newRewards = (lastBlockRewardApplicable() - lastUpdateBlock) * rewardRate;
            queuedRewards += newRewards;
            lastUpdateBlock = lastBlockRewardApplicable();
            if (account != address(0)) {
                userRewardPerTokenPaid[account] = rewardPerTokenStored;
            }
        }
    }
}

contract Exploit {
    address public constant ALICE = address(0xA11CE);
    address public constant BOB = address(0xB0B);
    uint256 public constant STAKE = 100 ether;

    RewardToken public token;
    Rewarder public rewarder;
    RewarderFixed public fixedRewarder;
    uint256 public lost;
    uint256 public queuedPaid;

    constructor() {
        token = new RewardToken();
        rewarder = new Rewarder(token);
        fixedRewarder = new RewarderFixed(token);
    }

    function _run(RewarderBase r, bool sweep) internal {
        token.mint(address(r), 1_500 ether);
        r.setClock(0);
        r.stake(ALICE, STAKE);
        r.setClock(5);
        r.withdraw(ALICE, STAKE);
        r.setClock(10);
        r.stake(BOB, STAKE);
        r.setClock(15);
        r.getReward(BOB);
        r.getReward(ALICE);
        if (sweep) r.claimQueued(address(this));
    }

    function run() external {
        _run(rewarder, true);
        lost = token.balanceOf(address(rewarder));
        require(token.balanceOf(ALICE) == 500 ether, "alice");
        require(token.balanceOf(BOB) == 500 ether, "bob");
        require(rewarder.queuedRewards() == 0, "no queue");
        require(lost == 500 ether, "lost");
        require(token.balanceOf(address(this)) == 0, "sweep");
    }

    function runControl() external {
        _run(fixedRewarder, true);
        queuedPaid = token.balanceOf(address(this));
        require(token.balanceOf(ALICE) == 500 ether, "alice");
        require(token.balanceOf(BOB) == 500 ether, "bob");
        require(queuedPaid == 500 ether, "queued");
        require(token.balanceOf(address(fixedRewarder)) == 0, "empty");
    }
}
