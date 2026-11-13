// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Hyperstable RewardsDistributor — perpetual locks score zero voting power
    (Pashov, 2025-03-19, H-02).
    SYNTHETIC, cheatcode-free. ve_for_at is the audited `bias - slope * time`.

    A perpetual lock is stored with bias = 0 and slope = 0, so the formula
    returns 0. An equal non-perpetual lock keeps bias = locked amount.
    1,000 reward tokens are paid entirely to the decaying lock.
    The 7 days are an argument to ve_for_at, not a warp. */

contract RewardToken {
    string public constant name = "PEG";
    string public constant symbol = "PEG";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RewardsDistributor {
    struct Point {
        int128 bias;
        int128 slope;
    }

    RewardToken public token;
    uint256 public nextId;
    uint256 public perpId;
    uint256 public normalId;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public lockedAmount;
    mapping(uint256 => Point) public points;
    mapping(uint256 => bool) public perpetual;

    constructor(RewardToken token_) {
        token = token_;
    }

    function createPerpetual(address owner, uint256 amount) external returns (uint256 id) {
        id = ++nextId;
        ownerOf[id] = owner;
        lockedAmount[id] = amount;
        perpetual[id] = true;
        // Perpetual locks are initialized with bias = 0 and slope = 0.
        points[id] = Point({bias: 0, slope: 0});
        perpId = id;
    }

    function createNormal(address owner, uint256 amount) external returns (uint256 id) {
        id = ++nextId;
        ownerOf[id] = owner;
        lockedAmount[id] = amount;
        points[id] = Point({bias: int128(uint128(amount)), slope: 0});
        normalId = id;
    }

    function ve_for_at(uint256 tokenId, uint256 t) public view returns (uint256) {
        Point memory pt = points[tokenId];
        int256 bias = int256(pt.bias) - int256(pt.slope) * int256(t);
        // @> VULN: bias - slope * time is zero for a perpetual lock
        if (bias < 0) return 0;
        return uint256(bias);
    }

    function claim(uint256 tokenId, uint256 t) external returns (uint256 amount) {
        uint256 power = ve_for_at(tokenId, t);
        uint256 total = ve_for_at(perpId, t) + ve_for_at(normalId, t);
        uint256 pot = token.balanceOf(address(this));
        if (total == 0 || pot == 0) return 0;
        amount = pot * power / total;
        if (amount > 0) token.transfer(ownerOf[tokenId], amount);
    }
}

contract RewardsDistributorFixed {
    RewardToken public token;
    uint256 public perpId = 1;
    uint256 public normalId = 2;
    uint256 public snapshot;
    bool public snapped;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint256) public lockedAmount;

    constructor(RewardToken token_) {
        token = token_;
    }

    function createPerpetual(address owner, uint256 amount) external {
        ownerOf[perpId] = owner;
        lockedAmount[perpId] = amount;
    }

    function createNormal(address owner, uint256 amount) external {
        ownerOf[normalId] = owner;
        lockedAmount[normalId] = amount;
    }

    function ve_for_at(uint256 tokenId, uint256) public view returns (uint256) {
        return lockedAmount[tokenId];
    }

    function claim(uint256 tokenId, uint256 t) external returns (uint256 amount) {
        uint256 power = ve_for_at(tokenId, t);
        uint256 total = lockedAmount[perpId] + lockedAmount[normalId];
        if (!snapped) {
            snapshot = token.balanceOf(address(this));
            snapped = true;
        }
        if (total == 0 || snapshot == 0) return 0;
        amount = snapshot * power / total;
        if (amount > 0) token.transfer(ownerOf[tokenId], amount);
    }
}

contract NormalLocker {
    function balance(RewardToken token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract Exploit {
    uint256 public constant LOCK = 1_000 ether;
    uint256 public constant REWARD = 1_000 ether;
    uint256 public constant T = 7 days;

    RewardToken public token; // nonce 1
    RewardsDistributor public dist; // nonce 2
    NormalLocker public normal; // nonce 3

    uint256 public perpPower;
    uint256 public normalPower;
    uint256 public perpPaid;
    uint256 public normalPaid;

    constructor() {
        token = new RewardToken();
        dist = new RewardsDistributor(token);
        normal = new NormalLocker();
        token.mint(address(dist), REWARD);
        dist.createPerpetual(address(this), LOCK);
        dist.createNormal(address(normal), LOCK);
    }

    function run() external {
        perpPower = dist.ve_for_at(dist.perpId(), T);
        normalPower = dist.ve_for_at(dist.normalId(), T);
        perpPaid = dist.claim(dist.perpId(), T);
        normalPaid = dist.claim(dist.normalId(), T);
        require(perpPower == 0, "perpetual power is 0");
        require(normalPower == LOCK, "normal power stays");
        require(perpPaid == 0, "perpetual paid 0");
        require(normalPaid == REWARD, "decaying lock took 1000");
        require(token.balanceOf(address(normal)) == REWARD, "1000 sits with the decaying lock");
        require(token.balanceOf(address(this)) == 0, "perpetual holder got nothing");
    }
}
