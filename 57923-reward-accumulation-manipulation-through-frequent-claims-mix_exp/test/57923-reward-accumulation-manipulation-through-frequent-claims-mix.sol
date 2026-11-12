// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  DIA Lumina — frequent claims floor the day and move the reward clock
    (MixBytes, finding 57923).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    daysElapsed = (now - lastUpdate) / 1 days. A 1.5 day gap floors to 1 day,
    pays 100, and sets lastUpdate to now, so the leftover half day is burned.
    A second claim in the same block pays 0. The precision formula pays 150.
    The blamed clock write is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Staking Reward";
    string public symbol = "DIA";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Staking {
    uint256 public constant SECONDS_IN_A_DAY = 1 days;
    uint256 public constant RATE = 100 ether;
    uint256 public constant PRINCIPAL = 10000;

    MockToken public token;
    uint256 public rewardLastUpdateTime;
    uint256 public rewardAccumulator;
    uint256 public userSnapshot;
    uint256 public daysElapsedStored;
    uint256 public claimCount;
    uint256 public firstPaid;
    uint256 public secondPaid;
    uint256 public openedAt;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function open(address user, uint256 lastUpdate) external {
        userSnapshot = 0;
        rewardAccumulator = 0;
        rewardLastUpdateTime = lastUpdate;
        openedAt = lastUpdate;
        user;
    }

    function claim(address user) external returns (uint256 reward) {
        _updateRewardAccumulator();
        uint256 delta = rewardAccumulator - userSnapshot;
        userSnapshot = rewardAccumulator;
        reward = (delta * PRINCIPAL) / 10000;
        if (claimCount == 0) {
            firstPaid = reward;
        } else {
            secondPaid = reward;
        }
        claimCount += 1;
        if (reward > 0) token.transfer(user, reward);
    }

    // Quoted _updateRewardAccumulator before the "only when a full day elapsed" guard.
    function _updateRewardAccumulator() internal {
        uint256 daysElapsed = (block.timestamp - rewardLastUpdateTime) / SECONDS_IN_A_DAY;
        daysElapsedStored = daysElapsed;
        rewardAccumulator += RATE * daysElapsed;
        // @> VULN: the clock jumps to now even when the division dropped a partial day
        this.commitClock(block.timestamp);
        // FIX: rewardLastUpdateTime += SECONDS_IN_A_DAY * daysElapsed
    }

    function commitClock(uint256 nextClock) external {
        require(msg.sender == address(this), "self");
        // @> VULN: the clock jumps to now even when the division dropped a partial day
        rewardLastUpdateTime = nextClock;
    }

    function fairReward() public view returns (uint256) {
        uint256 timeElapsed = ((block.timestamp - openedAt) * 1e18) / SECONDS_IN_A_DAY;
        uint256 accrued = (RATE * timeElapsed) / 1e18;
        return (accrued * PRINCIPAL) / 10000;
    }
}

contract StakingFixed {
    uint256 public constant RATE = 100 ether;
    MockToken public token;
    uint256 public openedAt;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function open(uint256 lastUpdate) external {
        openedAt = lastUpdate;
    }

    function claim(address user) external returns (uint256 reward) {
        uint256 timeElapsed = ((block.timestamp - openedAt) * 1e18) / 1 days;
        reward = (RATE * timeElapsed) / 1e18;
        token.transfer(user, reward);
    }
}

contract Exploit {
    uint256 public constant GAP = 1 days + 12 hours;

    MockToken public token;
    Staking public staking;
    uint256 public firstPaid;
    uint256 public secondPaid;
    uint256 public fair;
    uint256 public burned;

    constructor() {
        token = new MockToken();
        staking = new Staking(address(token));
    }

    function run() external {
        token.mint(address(staking), 150 ether);
        uint256 lastUpdate = block.timestamp - GAP;
        staking.open(address(this), lastUpdate);
        staking.claim(address(this));
        firstPaid = staking.firstPaid();
        fair = staking.fairReward();
        staking.claim(address(this));
        secondPaid = staking.secondPaid();
        burned = fair - firstPaid;
        require(staking.daysElapsedStored() == 0, "second claim did not floor to 0 days");
        require(firstPaid == 100 ether, "first claim is not 100");
        require(secondPaid == 0, "second claim paid something");
        require(fair == 150 ether, "fair is not 150");
        require(burned == 50 ether, "burned half day is not 50");
        require(token.balanceOf(address(this)) == 100 ether, "staker balance");
    }
}
