// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Roots finding 55113 (H-03):
// "Incorrect boost management leads to staking reward loss".
//
// Real audited source (report:
//   github.com/pashov/audits/blob/master/team/md/Roots-security-review_2025-02-09.md)
//   - Staker.sol :: _redeemRewards   (L305-307)  — VERBATIM, the vulnerable line is @>
//   - Staker.sol :: setValidator     (L80-83)    — VERBATIM, same missing-queue bug
//   - BGT reward cache (0x656b95E550C07a9ffe548bd4085c72418Ceb1dba):
//         queueDropBoost(bytes,uint128)          — VERBATIM (finding fragment #1)
//         dropBoost(address,bytes) returns bool  — VERBATIM header (finding fragment #2)
//
// Root cause: `Staker::_redeemRewards` and `Staker::setValidator` call
// `rewardCache.dropBoost(...)` WITHOUT first calling `rewardCache.queueDropBoost(...)`.
// The BGT `dropBoost` reads the `dropBoostQueue[user][pubkey]` entry and returns
// `false` when it is empty (`amount == 0`). Because the queue is never populated,
// `dropBoost` ALWAYS returns false: the boost is never actually dropped, so the
// boosted rewards a redeeming user is owed (`toFulfill`) are never freed and never
// delivered — the reward is silently lost / stuck in the reward cache.
//
// The vulnerable Staker call sites and the BGT queue/drop functions are reproduced
// byte-for-byte from the audited source. Non-vulnerable dependencies (the ERC20
// reward token, the boost bookkeeping, the Roots `RewardCache` wrapper that maps a
// validator address to its pubkey) are faithful minimal doubles with real accounting.
//
// The harm is a SILENT reward loss (no positive transfer to any attacker): the
// redeeming user receives 0 instead of `toFulfill`, and `toFulfill` reward tokens
// stay stuck in the BGT reward cache. Per authoring convention the lost magnitude is
// minted to SINK 0x000000000000000000000000000000000000D00d on a marker token.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the on-chain `.selector.revertWith()` helper so the verbatim
///      `queueDropBoost` body compiles exactly as written in the audited source.
library CustomRevert {
    function revertWith(bytes4 selector) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, selector)
            revert(0x00, 0x04)
        }
    }
}

/// @dev Faithful minimal ERC20 double for the redeemable staking reward.
contract MiniToken {
    string public name = "Roots Staking Reward";
    string public symbol = "rsREWARD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Marker token used only to record the SILENTLY-LOST reward magnitude at SINK.
contract LossMarker {
    string public name = "Roots Reward Loss Marker";
    string public symbol = "LOSS";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BGT reward cache — faithful double of the Berachain BGT at
// 0x656b95E550C07a9ffe548bd4085c72418Ceb1dba. `queueDropBoost` and the header of
// `dropBoost` are reproduced VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract BGT {
    using CustomRevert for bytes4;

    error NotEnoughBoostedBalance();

    event QueueDropBoost(address indexed user, bytes indexed pubkey, uint128 amount);
    event DropBoost(address indexed user, bytes indexed pubkey, uint128 amount);

    struct QueuedDropBoost {
        uint128 balance;
        uint32 blockNumberLast;
    }

    MiniToken public immutable reward;
    uint32 public dropBoostDelay; // 0 in this reproduction; the queue-empty check is the blocker

    // user (booster) => pubkey => boosted BGT balance
    mapping(address => mapping(bytes => uint128)) public boosted;
    // user (booster) => pubkey => queued drop entry
    mapping(address => mapping(bytes => QueuedDropBoost)) public dropBoostQueue;
    // user (booster) => total boosts (the finding uses `rewardCache.boosts(...)`)
    mapping(address => uint128) public boosts;

    constructor(MiniToken _reward) {
        reward = _reward;
    }

    function _checkEnoughTimePassed(uint32 blockNumberLast, uint32 delay) internal view returns (bool) {
        return block.number >= uint256(blockNumberLast) + uint256(delay);
    }

    /// @notice Faithful boost bookkeeping (not the vulnerable path). Records that
    ///         `msg.sender` boosted `pubkey` with `amount`; the reward backing the
    ///         boost is expected to already sit in this cache.
    function boost(bytes calldata pubkey, uint128 amount) external {
        boosted[msg.sender][pubkey] += amount;
        boosts[msg.sender] += amount;
    }

    // ── VERBATIM: BGT.queueDropBoost (finding fragment #1) ──
    function queueDropBoost(bytes calldata pubkey, uint128 amount) external {
        QueuedDropBoost storage qdb = dropBoostQueue[msg.sender][pubkey];
        uint128 dropBalance = qdb.balance + amount;
        // check if the user has enough boosted balance to drop
        if (boosted[msg.sender][pubkey] < dropBalance) NotEnoughBoostedBalance.selector.revertWith();
        (qdb.balance, qdb.blockNumberLast) = (dropBalance, uint32(block.number));
        emit QueueDropBoost(msg.sender, pubkey, amount);
    }

    // ── VERBATIM header: BGT.dropBoost (finding fragment #2); body completed faithfully ──
    function dropBoost(address user, bytes calldata pubkey) external returns (bool) {
        QueuedDropBoost storage qdb = dropBoostQueue[user][pubkey];
        (uint32 blockNumberLast, uint128 amount) = (qdb.blockNumberLast, qdb.balance);
        // `amount` must be greater than zero to avoid reverting as
        // `withdraw` will fail with zero amount.
        if (amount == 0 || !_checkEnoughTimePassed(blockNumberLast, dropBoostDelay)) return false;
        // drop succeeded: reduce the boost and free the backing reward to the booster.
        boosted[user][pubkey] -= amount;
        boosts[user] -= amount;
        qdb.balance = 0;
        reward.transfer(user, amount);
        emit DropBoost(user, pubkey, amount);
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Roots `RewardCache` wrapper — the object the Staker references as `rewardCache`.
// It maps a validator ADDRESS (as used at the Staker call sites) to its BGT pubkey
// and forwards to the BGT. `queueDropBoost` is exposed but the Staker never calls it.
// Faithful minimal double; the wrapper is the on-chain booster (msg.sender to BGT).
// ─────────────────────────────────────────────────────────────────────────────
contract RewardCache {
    BGT public immutable bgt;
    MiniToken public immutable reward;

    constructor(BGT _bgt, MiniToken _reward) {
        bgt = _bgt;
        reward = _reward;
    }

    function _pubkey(address validator) internal pure returns (bytes memory) {
        return abi.encodePacked(validator);
    }

    /// @notice Total boosts held for this reward cache (Staker's boosted position).
    function boosts(address) external view returns (uint256) {
        return bgt.boosts(address(this));
    }

    /// @notice Correct usage: queue a future drop of `amount` for `validator`.
    ///         (Never called by the vulnerable Staker — that is the bug.)
    function queueDropBoost(address validator, uint128 amount) external {
        bgt.queueDropBoost(_pubkey(validator), amount);
    }

    /// @notice Drop the boost for `validator`. Forwards the freed reward to the
    ///         caller on success. Returns BGT's bool result (false when unqueued).
    function dropBoost(address validator, uint128) external returns (bool) {
        bool ok = bgt.dropBoost(address(this), _pubkey(validator));
        if (ok) {
            uint256 freed = reward.balanceOf(address(this));
            if (freed > 0) reward.transfer(msg.sender, freed);
        }
        return ok;
    }

    /// @notice Faithful boost setup: fund the backing reward into the BGT cache and
    ///         record the boosted balance for this cache.
    function boost(address validator, uint128 amount) external {
        reward.transferFrom(msg.sender, address(bgt), amount);
        bgt.boost(_pubkey(validator), amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — Roots `Staker`. The `_redeemRewards` and `setValidator`
// branches are reproduced VERBATIM from the audited source; both call `dropBoost`
// without a preceding `rewardCache.queueDropBoost`, so the drop always fails.
// ─────────────────────────────────────────────────────────────────────────────
contract Staker {
    RewardCache public rewardCache;
    MiniToken public reward;
    address public validator;

    // pending reward redemption requested by a user (amount to be freed via dropBoost)
    mapping(address => uint256) public pendingRedemption;

    constructor(RewardCache _rewardCache, MiniToken _reward, address _validator) {
        rewardCache = _rewardCache;
        reward = _reward;
        validator = _validator;
    }

    /// @notice A user requests to redeem `amount` of their boosted rewards.
    function requestRedeem(address user, uint256 amount) external {
        pendingRedemption[user] += amount;
    }

    /// @notice Redeem rewards for `user`. The dropBoost branch is VERBATIM Staker.sol
    ///         L305-307. Whatever the drop frees to this contract is delivered to the
    ///         user; when the drop silently fails, the user receives nothing.
    function _redeemRewards(address user) internal {
        uint256 toFulfill = pendingRedemption[user];

        // Determine how much boosted reward must be dropped to fund the redemption,
        // then drop it (VERBATIM audited branch):
        if (toFulfill > 0) {
            rewardCache.dropBoost(validator, uint128(toFulfill)); // @> VULN: dropBoost called without a preceding rewardCache.queueDropBoost -> dropBoostQueue is empty -> BGT.dropBoost returns false -> boost never dropped, toFulfill reward never freed (silent reward loss)
        }

        // Deliver whatever reward the drop freed into this contract to the user.
        uint256 freed = reward.balanceOf(address(this));
        pendingRedemption[user] = 0;
        if (freed > 0) reward.transfer(user, freed);
    }

    function redeemRewards(address user) external {
        _redeemRewards(user);
    }

    /// @notice Change the validator. VERBATIM audited branch (Staker.sol L80-83):
    ///         drops the old validator's boost before switching — but again without
    ///         a preceding queueDropBoost, so the boost is never actually dropped.
    function setValidator(address _newValidator) external {
        address oldValidator = validator;
        uint256 boosted = rewardCache.boosts(address(this));
        if (boosted > 0) {
            rewardCache.dropBoost(oldValidator, uint128(boosted)); // @> VULN: same missing-queue bug — drop silently fails, old boost stays stuck
        }
        validator = _newValidator;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a Staker boosts a validator with 1000e18 of reward on behalf of a
// user; the user requests to redeem it; `_redeemRewards` calls `dropBoost` WITHOUT
// queueing, so the drop returns false, the boost is never removed, and the user is
// paid 0. The 1000e18 owed reward is stuck in the BGT cache — a silent reward loss.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant USER = 0x00000000000000000000000000000000000b0057; // the redeeming user
    address internal constant VALIDATOR = 0x000000000000000000000000000000000000bEEF;

    uint128 internal constant BOOSTED = 1000e18; // reward boosted on the validator on the user's behalf

    MiniToken public reward;
    BGT public bgt;
    RewardCache public rewardCache;
    Staker public vuln; // Roots Staker — holds the vulnerable code
    LossMarker public lossMarker;

    // harm metrics
    uint256 public expectedReward; // what the user should have received
    uint256 public userReceived; // what the user actually received
    uint256 public boostedBefore;
    uint256 public boostedAfter;
    uint256 public rewardStuckInCache;
    bool public dropReturnedFalse;
    uint256 public lostReward; // magnitude minted to SINK

    constructor() {
        reward = new MiniToken(); // child nonce 1
        bgt = new BGT(reward); // child nonce 2
        rewardCache = new RewardCache(bgt, reward); // child nonce 3
        vuln = new Staker(rewardCache, reward, VALIDATOR); // child nonce 4 (VULN)
        lossMarker = new LossMarker(); // child nonce 5 (marker / profit token)
    }

    function run() external {
        // 1) Set up the boosted position: the reward cache boosts the validator with
        //    1000e18 of reward on the user's behalf (reward is escrowed in the BGT cache).
        reward.mint(address(this), BOOSTED);
        reward.approve(address(rewardCache), type(uint256).max);
        rewardCache.boost(VALIDATOR, BOOSTED);

        boostedBefore = bgt.boosts(address(rewardCache));
        require(boostedBefore == BOOSTED, "setup: boost not recorded");
        require(reward.balanceOf(address(bgt)) == BOOSTED, "setup: reward not escrowed");

        // 2) The user requests to redeem the full boosted reward.
        vuln.requestRedeem(USER, BOOSTED);
        expectedReward = BOOSTED;

        // 3) Redeem — hits the VERBATIM vulnerable branch. dropBoost is called with no
        //    prior queueDropBoost, so it silently returns false and frees nothing.
        vuln.redeemRewards(USER);
        userReceived = reward.balanceOf(USER);

        // 4) Observe the silent failure: boost was never dropped, reward stuck in cache.
        boostedAfter = bgt.boosts(address(rewardCache));
        rewardStuckInCache = reward.balanceOf(address(bgt));

        // Explicit proof the drop returns false while the queue is empty (no side effects).
        dropReturnedFalse = !rewardCache.dropBoost(VALIDATOR, BOOSTED);

        // Record the silently-lost reward magnitude at SINK.
        lostReward = expectedReward - userReceived;
        lossMarker.mint(SINK, lostReward);

        // ── HARM ──
        require(userReceived == 0, "user unexpectedly received reward");
        require(boostedAfter == boostedBefore, "boost was actually dropped");
        require(dropReturnedFalse, "dropBoost did not return false");
        require(rewardStuckInCache == BOOSTED, "reward not stuck in cache");
        require(lostReward == BOOSTED, "unexpected loss magnitude");
        require(lossMarker.balanceOf(SINK) == BOOSTED, "loss not recorded at sink");
    }
}
