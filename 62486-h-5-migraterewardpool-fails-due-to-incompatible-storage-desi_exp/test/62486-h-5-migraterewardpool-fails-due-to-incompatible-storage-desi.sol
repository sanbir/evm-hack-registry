// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of Notional Exponent finding 62486 (H-5):
// "`migrateRewardPool` Fails Due to Incompatible Storage Design in CurveConvexLib".
//
// Source: sherlock-audit/2025-06-notional-exponent
//   notional-v4/src/rewards/AbstractRewardManager.sol  (migrateRewardPool, L44-65)
// `migrateRewardPool` is reproduced VERBATIM (the @> marks the storage write that
// is ineffective).
//
// Root cause: `migrateRewardPool` updates the reward pool in STORAGE
// (`_getRewardPoolSlot().rewardPool = newRewardPool.rewardPool`). But new LP
// deposits are routed by `CurveConvex2Token`/`CurveConvexLib`, where the reward
// pool address is IMMUTABLE (fixed at deployment). So after a migration the
// storage says "new pool" while every new deposit still goes to the OLD,
// deprecated pool — the migration silently has no effect.
// ─────────────────────────────────────────────────────────────────────────────

struct RewardPoolStorage {
    address rewardPool;
    uint32 lastClaimTimestamp;
    uint32 forceClaimAfter;
}

interface IRewardPool {
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function staked() external view returns (uint256);
}

/// @dev Faithful Convex-style reward pool: tracks staked LP.
contract MockRewardPool is IRewardPool {
    uint256 public staked;
    function stake(uint256 amount) external { staked += amount; }
    function withdraw(uint256 amount) external { staked -= amount; }
}

/// @dev Marker token used to record the misdirected-deposit magnitude for measurement.
contract MiniToken {
    string public name = "MISDIRECTED-LP";
    string public symbol = "mLP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

/// @dev The token/strategy that actually routes deposits. Its reward pool is
///      IMMUTABLE (as in CurveConvexLib) — this is the incompatible design.
contract CurveConvex2Token {
    IRewardPool public immutable rewardPool; // @> VULN: immutable — never follows a migrateRewardPool storage change
    constructor(IRewardPool _rewardPool) { rewardPool = _rewardPool; }
    /// @notice Every LP deposit is staked into the IMMUTABLE pool.
    function depositLp(uint256 amount) external { rewardPool.stake(amount); }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `migrateRewardPool` reproduced VERBATIM (storage write).
// ─────────────────────────────────────────────────────────────────────────────
contract AbstractRewardManager {
    RewardPoolStorage internal _rewardPoolSlot;
    CurveConvex2Token public strategy; // routes deposits via its IMMUTABLE pool

    function _getRewardPoolSlot() internal view returns (RewardPoolStorage storage s) { return _rewardPoolSlot; }
    function rewardPoolInStorage() external view returns (address) { return _rewardPoolSlot.rewardPool; }
    function setStrategy(CurveConvex2Token s) external { strategy = s; }
    function initRewardPool(address pool) external { _rewardPoolSlot.rewardPool = pool; }

    function _claimVaultRewards(uint256, bytes32) internal {}
    function _withdrawFromPreviousRewardPool(RewardPoolStorage memory old) internal {
        if (old.rewardPool != address(0)) IRewardPool(old.rewardPool).withdraw(IRewardPool(old.rewardPool).staked());
    }
    function _depositIntoNewRewardPool(address, uint256 amount, RewardPoolStorage memory newPool) internal {
        if (amount > 0) IRewardPool(newPool.rewardPool).stake(amount);
    }

    /// @notice Existing LP the manager holds and migrates.
    uint256 public poolTokenBalance;
    function setPoolTokenBalance(uint256 b) external { poolTokenBalance = b; }

    // ── VERBATIM migrateRewardPool from the audited source (setter portion) ──
    function migrateRewardPool(address poolToken, RewardPoolStorage memory newRewardPool) external {
        // Claim all rewards from the previous reward pool before withdrawing
        _claimVaultRewards(0, bytes32(0));
        RewardPoolStorage memory oldRewardPool = _getRewardPoolSlot();

        if (oldRewardPool.rewardPool != address(0)) {
            _withdrawFromPreviousRewardPool(oldRewardPool);
        }

        uint256 poolTokens = poolTokenBalance; // ERC20(poolToken).balanceOf(address(this))
        _depositIntoNewRewardPool(poolToken, poolTokens, newRewardPool);

        _getRewardPoolSlot().lastClaimTimestamp = uint32(block.timestamp);
        _getRewardPoolSlot().rewardPool = newRewardPool.rewardPool; // @> VULN: updates the reward pool in STORAGE only; new deposits route through the strategy's IMMUTABLE pool, so this migration has no effect on future deposits
        _getRewardPoolSlot().forceClaimAfter = newRewardPool.forceClaimAfter;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: migrate to a new pool, then deposit fresh LP and show it lands
// in the OLD immutable pool while storage claims the new one — migration broken.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant NEW_DEPOSIT = 100e18;

    MiniToken public marker;            // child nonce 1 (records misdirected LP)
    MockRewardPool public oldPool;      // child nonce 2
    MockRewardPool public newPool;      // child nonce 3
    AbstractRewardManager public vuln;  // child nonce 4 (VULN)
    CurveConvex2Token public strategy;  // child nonce 5

    uint256 public depositedToOldPool;
    uint256 public depositedToNewPool;
    address public storageSaysPool;

    constructor() {
        marker = new MiniToken();                       // nonce 1
        oldPool = new MockRewardPool();                 // nonce 2
        newPool = new MockRewardPool();                 // nonce 3
        vuln = new AbstractRewardManager();             // nonce 4
        strategy = new CurveConvex2Token(IRewardPool(address(oldPool))); // nonce 5 — immutable = oldPool
    }

    function run() external {
        vuln.setStrategy(strategy);
        vuln.initRewardPool(address(oldPool));

        // Convex deprecates oldPool; admin migrates the manager to newPool
        RewardPoolStorage memory np = RewardPoolStorage({ rewardPool: address(newPool), lastClaimTimestamp: 0, forceClaimAfter: 0 });
        vuln.migrateRewardPool(address(0x11), np);
        storageSaysPool = vuln.rewardPoolInStorage(); // == newPool

        uint256 oldBefore = oldPool.staked();
        uint256 newBefore = newPool.staked();

        // a user deposits fresh LP AFTER migration — routed by the strategy's IMMUTABLE pool
        strategy.depositLp(NEW_DEPOSIT);

        depositedToOldPool = oldPool.staked() - oldBefore;
        depositedToNewPool = newPool.staked() - newBefore;

        // harm: storage migrated to newPool, but the deposit went to the deprecated oldPool
        require(storageSaysPool == address(newPool), "storage did not migrate");
        require(depositedToOldPool == NEW_DEPOSIT, "deposit did not go to old pool");
        require(depositedToNewPool == 0, "deposit unexpectedly reached new pool");

        // record the misdirected (into a deprecated pool) deposit magnitude on the marker
        marker.mint(SINK, NEW_DEPOSIT);
    }
}
