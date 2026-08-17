// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Kinetiq finding 58609 (H-01):
// "_AddRebalanceRequest may use outdated balance for delegate withdrawal request".
//
// Real audited source (the vulnerable function `_addRebalanceRequest` is
// reproduced VERBATIM from the finding's embedded snippet; the marked line @>):
//   protocol Kinetiq  (Pashov Audit Group, 2025-02-26)
//   contract ValidatorManager
//   fn       _addRebalanceRequest
//   report   github.com/pashov/audits/blob/master/team/md/Kinetiq-security-review_2025-02-26.md
//
// Root cause: `_addRebalanceRequest` validates `_validators[index].balance >=
// withdrawalAmount` at REQUEST time, then persists a FIXED `amount`
// (the @> line). `closeRebalanceRequest()` later withdraws that stale stored
// `amount` — it never re-reads the validator's live balance. A validator's
// balance changes at any time (rewards / slashing) on HyperLiquid, so at close
// time either (1) the balance decreased and the undelegation reverts (funds
// frozen), or (2) the balance increased and the surplus stays stuck in the
// validator — even though a deactivation / emergency withdrawal must retrieve
// ALL funds. Because the pending-rebalance set blocks re-adding a request, the
// surplus cannot be swept.
//
// This PoC demonstrates case (2): the manager records a full-balance withdrawal
// request, rewards accrue, and `closeRebalanceRequest()` retrieves only the
// stale amount, leaving the reward permanently stuck in the validator.
//
// The `_addRebalanceRequest` body is byte-for-byte the audited source. The
// minimal `EnumerableSet` / `EnumerableMap` libraries below recreate exactly the
// OpenZeppelin members the verbatim line uses, so it stays identical. Everything
// else (HYPE token, HyperLiquid staking layer, `closeRebalanceRequest`) is a
// faithful minimal double with real transfers and real accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal recreation of the OZ `EnumerableSet.AddressSet` members
///      the verbatim code uses (`contains`, `add`, `remove`).
library EnumerableSet {
    struct AddressSet {
        mapping(address => bool) _present;
        address[] _values;
    }

    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return set._present[value];
    }

    function add(AddressSet storage set, address value) internal returns (bool) {
        if (set._present[value]) return false;
        set._present[value] = true;
        set._values.push(value);
        return true;
    }

    function remove(AddressSet storage set, address value) internal returns (bool) {
        if (!set._present[value]) return false;
        set._present[value] = false;
        return true;
    }
}

/// @dev Faithful minimal recreation of the OZ `EnumerableMap.AddressToUintMap`
///      members the verbatim code uses (`tryGet`, plus `set` for registration).
library EnumerableMap {
    struct AddressToUintMap {
        mapping(address => uint256) _values;
        mapping(address => bool) _present;
    }

    function set(AddressToUintMap storage map, address key, uint256 value) internal returns (bool) {
        bool existed = map._present[key];
        map._present[key] = true;
        map._values[key] = value;
        return !existed;
    }

    function tryGet(AddressToUintMap storage map, address key) internal view returns (bool, uint256) {
        return (map._present[key], map._values[key]);
    }
}

/// @dev Faithful minimal ERC20 double for HYPE (the staked asset).
contract HYPE {
    string public name = "Hyperliquid";
    string public symbol = "HYPE";
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

/// @dev Faithful double of the HyperLiquid staking layer. It custodies the HYPE
///      actually delegated to each validator. `delegate` moves stake in,
///      `accrueReward` credits a validator's live stake, and `undelegate`
///      pays a requested amount back to the manager (reverting if the live
///      stake is insufficient — the case-(1) revert). `stakeOf` reads the live,
///      up-to-date validator balance that the vulnerable close path ignores.
contract StakingL1 {
    HYPE public hype;
    mapping(address => uint256) public stakeOf; // validator => live delegated HYPE

    constructor(HYPE h) {
        hype = h;
    }

    function delegate(address validator, uint256 amount) external {
        hype.transferFrom(msg.sender, address(this), amount);
        stakeOf[validator] += amount;
    }

    function accrueReward(address validator, uint256 amount) external {
        // rewards arrive on L1 and grow the validator's live delegated balance
        hype.mint(address(this), amount);
        stakeOf[validator] += amount;
    }

    function undelegate(address validator, address to, uint256 amount) external {
        require(stakeOf[validator] >= amount, "insufficient live stake"); // case (1): reverts if balance dropped
        stakeOf[validator] -= amount;
        hype.transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `_addRebalanceRequest` is reproduced VERBATIM from the
// audited Kinetiq `ValidatorManager`. `closeRebalanceRequest` and the supporting
// storage are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────
contract ValidatorManager {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    struct Validator {
        address validator;
        uint256 balance;
    }

    struct RebalanceRequest {
        address validator;
        uint256 amount;
    }

    Validator[] private _validators;
    EnumerableMap.AddressToUintMap private _validatorIndexes;
    EnumerableSet.AddressSet private _validatorsWithPendingRebalance;
    mapping(address => RebalanceRequest) public validatorRebalanceRequests;

    StakingL1 internal L1;

    event RebalanceRequestAdded(address validator, uint256 amount);

    constructor(StakingL1 l1_) {
        L1 = l1_;
    }

    // ── faithful registration double: mirrors validator onboarding + delegation ──
    function registerValidator(address validator, uint256 balance) external {
        _validatorIndexes.set(validator, _validators.length);
        _validators.push(Validator({validator: validator, balance: balance}));
    }

    /// @dev keeps the manager's tracked balance in sync when the live L1 stake
    ///      grows via rewards (an oracle report on the real protocol).
    function reportBalance(address validator, uint256 newBalance) external {
        (bool exists, uint256 index) = _validatorIndexes.tryGet(validator);
        require(exists, "Validator does not exist");
        _validators[index].balance = newBalance;
    }

    // external entrypoint to the verbatim internal function
    function addRebalanceRequest(address validator, uint256 withdrawalAmount) external {
        _addRebalanceRequest(validator, withdrawalAmount);
    }

    // ─── VERBATIM from audited ValidatorManager._addRebalanceRequest ───
    function _addRebalanceRequest(address validator, uint256 withdrawalAmount) internal {
        require(!_validatorsWithPendingRebalance.contains(validator), "Validator has pending rebalance");
        require(withdrawalAmount > 0, "Invalid withdrawal amount");

        (bool exists, uint256 index) = _validatorIndexes.tryGet(validator);
        require(exists, "Validator does not exist");
        require(_validators[index].balance >= withdrawalAmount, "Insufficient balance");

        validatorRebalanceRequests[validator] = RebalanceRequest({validator: validator, amount: withdrawalAmount}); // @> VULN: persists a FIXED amount validated against the balance at REQUEST time; closeRebalanceRequest reuses this stale amount and never re-reads the live balance
        _validatorsWithPendingRebalance.add(validator);

        emit RebalanceRequestAdded(validator, withdrawalAmount);
    }
    // ─── end verbatim ───

    /// @notice Faithful double of `closeRebalanceRequest`: withdraws the STORED
    ///         (stale) request amount from L1 to the manager. It never re-reads
    ///         the validator's live balance, so surplus above the stale amount
    ///         stays stuck in the validator.
    function closeRebalanceRequest(address validator, address to) external {
        require(_validatorsWithPendingRebalance.contains(validator), "No pending rebalance");
        (bool exists, uint256 index) = _validatorIndexes.tryGet(validator);
        require(exists, "Validator does not exist");

        RebalanceRequest memory request = validatorRebalanceRequests[validator];

        // undelegate exactly the stale stored amount (NOT the live balance)
        L1.undelegate(validator, to, request.amount);
        _validators[index].balance -= request.amount;

        _validatorsWithPendingRebalance.remove(validator);
        delete validatorRebalanceRequests[validator];
    }

    // view helper for the harness
    function trackedBalance(address validator) external view returns (uint256) {
        (bool exists, uint256 index) = _validatorIndexes.tryGet(validator);
        require(exists, "Validator does not exist");
        return _validators[index].balance;
    }
}

/// @dev Marker token used to record the harm magnitude (the reward left stuck in
///      the validator after a "full deactivation" close). Minted to SINK, since
///      the harm is stuck/unretrievable funds rather than a transfer to an actor.
contract StuckMarker {
    string public name = "Kinetiq Stuck Validator Funds";
    string public symbol = "STUCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver — plays the Kinetiq manager deactivating a validator:
//   1) validator has 100e18 delegated; record a full-balance rebalance request
//   2) rewards accrue (+10e18) between request and close
//   3) closeRebalanceRequest retrieves only the stale 100e18
//   4) 10e18 of rewards remain permanently stuck in the validator
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    HYPE public hype;
    StakingL1 public l1;
    ValidatorManager public vuln;
    StuckMarker public marker;

    address internal constant VALIDATOR = address(0xBEEF);

    uint256 internal constant DELEGATED = 100e18; // validator's balance at request time
    uint256 internal constant REWARD = 10e18; // rewards that accrue before close

    uint256 public retrieved; // HYPE the manager got back on close
    uint256 public stuck; // HYPE left stranded in the validator after a full close

    constructor() {
        hype = new HYPE(); // child nonce 1
        l1 = new StakingL1(hype); // child nonce 2
        vuln = new ValidatorManager(l1); // child nonce 3 (VULN)
        marker = new StuckMarker(); // child nonce 4 (harm marker → SINK)
    }

    function run() external {
        // 1) delegate 100e18 HYPE to the validator via the manager
        hype.mint(address(this), DELEGATED);
        hype.approve(address(l1), type(uint256).max);
        l1.delegate(VALIDATOR, DELEGATED);
        vuln.registerValidator(VALIDATOR, DELEGATED);

        // 2) manager deactivates the validator → request withdrawal of its FULL
        //    current balance (100e18). The stored amount is now frozen.
        vuln.addRebalanceRequest(VALIDATOR, DELEGATED);

        // 3) rewards accrue on L1 before the request is closed; the live balance
        //    is now 110e18, and the manager's oracle reports it.
        l1.accrueReward(VALIDATOR, REWARD);
        vuln.reportBalance(VALIDATOR, DELEGATED + REWARD);

        // 4) close the request. It withdraws only the STALE stored amount.
        uint256 managerBefore = hype.balanceOf(address(this));
        vuln.closeRebalanceRequest(VALIDATOR, address(this));
        retrieved = hype.balanceOf(address(this)) - managerBefore;

        // the reward remains stranded in the validator despite full deactivation
        stuck = l1.stakeOf(VALIDATOR);

        // record harm magnitude to SINK
        marker.mint(SINK, stuck);

        // HARM: a full-balance deactivation retrieved only the stale amount,
        // leaving REWARD (10e18) permanently stuck in the validator.
        require(retrieved == DELEGATED, "close did not use the stale stored amount");
        require(stuck == REWARD, "no funds were left stuck");
        require(stuck > 0, "no harm");
        require(marker.balanceOf(SINK) == REWARD, "harm marker not recorded to sink");
    }
}
