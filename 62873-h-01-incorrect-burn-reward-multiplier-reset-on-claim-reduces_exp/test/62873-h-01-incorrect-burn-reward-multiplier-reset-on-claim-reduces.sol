// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Honeypot Finance NFTStaking finding
// 62873: "[H-01] Incorrect Burn Reward Multiplier Reset on _claim Reduces Accrual".
//
// The burn branch of _claim (src/NFTStaking.sol#L161) derives the reward
// multiplier from `sinceBurn = block.timestamp - burnedAt` and, on every claim,
// RESETS `s.burnedAt = block.timestamp`. Because `sinceBurn` is used BOTH as the
// multiplier input AND as the delta window, the reset collapses the multiplier
// reference to the tiny window since the *last* claim instead of scaling with the
// total burn duration. A burn staker who claims periodically therefore has the
// multiplier pinned near its minimum and is materially UNDER-PAID reward tokens
// relative to a staker who claims once at the end (whose single claim sees the
// full-duration multiplier).
//
// Faithfulness notes:
//  - The full `_claim` function is inlined VERBATIM from the finding (the elided
//    `// code` prologue is reconstructed as the `Stake storage s = stakes[...]`
//    pointer). The @> marker sits on the exact defective reset line.
//  - `_multiplier` is not embedded in the report; only its "longer duration ->
//    higher multiplier" contract is load-bearing, so it is represented by a
//    minimal MONOTONIC (capped-linear) double.
//  - A single transaction cannot advance `block.timestamp`, so elapsed windows
//    between successive claims are emulated by seeding the stake's timestamp
//    fields (the sanctioned storeSlot clock-emulation technique). The audited
//    accrual math and the reset behaviour run unchanged.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Rewards double: accumulates minted amounts per recipient (stand-in for the
///      opaque `rewards` ERC20 minter the staking contract calls).
contract MiniRewards {
    mapping(address => uint256) public mintedTo;
    uint256 public totalMinted;

    function mint(address to, uint256 amount) external {
        mintedTo[to] += amount;
        totalMinted += amount;
    }
}

/// @dev Minimal marker ERC20. Records the magnitude of the lost burn rewards at
///      the SINK so the harm is measurable as a balance delta.
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
// VULNERABLE contract: verbatim `_claim` (burn branch) inlined from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStaking {
    struct Stake {
        address owner;
        bool burned;
        uint64 burnedAt;
        uint64 stakedAt;
        uint64 lastClaimAt;
    }

    mapping(uint256 => Stake) public stakes;

    uint256 public constant ONE = 1e18;
    uint256 public constant MAX_BPS = 10000;
    uint256 public rewardRatePerSecond = 1e15;
    uint256 public burnBonusBps = 10000;

    // Monotonic, capped-linear stand-in for the opaque _multiplier. Only the
    // "longer elapsed -> larger multiplier (up to a cap)" property is load-bearing.
    uint256 internal constant MAX_MULT = 100e18; // 100x cap
    uint256 internal constant K_NUM = 99e18;
    uint256 internal constant K_DEN = 40 * 86400; // reaches the cap at 40 days

    MiniRewards public rewards;

    event BurnRewardClaimed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event RewardClaimed(address indexed user, uint256 indexed tokenId, uint256 amount);

    constructor(MiniRewards _rewards) {
        rewards = _rewards;
    }

    function _multiplier(uint256 elapsed) internal pure returns (uint256) {
        uint256 m = ONE + (K_NUM * elapsed) / K_DEN;
        if (m > MAX_MULT) m = MAX_MULT;
        return m;
    }

    function _claim(uint256 tokenId) internal returns (uint256 amount) {
        Stake storage s = stakes[tokenId];
        if (s.burned) {
            // Handle burn bonus claim
            require(s.burnedAt != 0, "INVALID_BURN_STATE");

            uint256 sinceBurn = block.timestamp - uint256(s.burnedAt);
            if (sinceBurn == 0) return 0;

            uint256 mBurn = _multiplier(sinceBurn);
            amount =
                (rewardRatePerSecond * sinceBurn * mBurn * burnBonusBps) /
                (ONE * MAX_BPS);

            if (amount == 0) return 0;

            // Update last burn claim time (resets multiplier reference)
            s.burnedAt = uint64(block.timestamp); // @> resets the burn multiplier reference on EVERY claim, pinning the multiplier near its minimum

            // Mint burn bonus rewards
            rewards.mint(msg.sender, amount);
            emit BurnRewardClaimed(msg.sender, tokenId, amount);

            return amount;
        }

        // Normal claim path: multiplier uses total elapsed since stakedAt and does not reset
        uint256 nowTs = block.timestamp;
        if (nowTs <= s.lastClaimAt) return 0;

        uint256 delta = nowTs - uint256(s.lastClaimAt);
        uint256 elapsed = nowTs - uint256(s.stakedAt);
        uint256 m = _multiplier(elapsed);

        amount = (rewardRatePerSecond * delta * m) / ONE;

        if (amount == 0) return 0;

        // Update last claim time
        s.lastClaimAt = uint64(nowTs);

        // Mint rewards
        rewards.mint(s.owner, amount);
        emit RewardClaimed(s.owner, tokenId, amount);
        return amount;
    }

    function claim(uint256 tokenId) external returns (uint256) {
        return _claim(tokenId);
    }

    // ── test-only clock/state seeding (models the audited entry state; not part
    //    of the audited logic) ──
    function seedBurnStake(uint256 tokenId, address stakeOwner, uint64 burnedAt_) external {
        Stake storage s = stakes[tokenId];
        s.owner = stakeOwner;
        s.burned = true;
        s.burnedAt = burnedAt_;
    }

    function setBurnedAt(uint256 tokenId, uint64 burnedAt_) external {
        stakes[tokenId].burnedAt = burnedAt_;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// NEGATIVE CONTROL: the report's recommended two-timestamp fix.
//   burnStartAt   — fixed reference for the multiplier, NEVER reset by a claim.
//   lastBurnClaimAt — separate reference for the delta window, reset each claim.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTStakingFixed {
    struct Stake {
        address owner;
        bool burned;
        uint64 burnStartAt;
        uint64 lastBurnClaimAt;
    }

    mapping(uint256 => Stake) public stakes;

    uint256 public constant ONE = 1e18;
    uint256 public constant MAX_BPS = 10000;
    uint256 public rewardRatePerSecond = 1e15;
    uint256 public burnBonusBps = 10000;

    uint256 internal constant MAX_MULT = 100e18;
    uint256 internal constant K_NUM = 99e18;
    uint256 internal constant K_DEN = 40 * 86400;

    MiniRewards public rewards;

    event BurnRewardClaimed(address indexed user, uint256 indexed tokenId, uint256 amount);

    constructor(MiniRewards _rewards) {
        rewards = _rewards;
    }

    function _multiplier(uint256 elapsed) internal pure returns (uint256) {
        uint256 m = ONE + (K_NUM * elapsed) / K_DEN;
        if (m > MAX_MULT) m = MAX_MULT;
        return m;
    }

    function _claim(uint256 tokenId) internal returns (uint256 amount) {
        Stake storage s = stakes[tokenId];
        if (s.burned) {
            require(s.burnStartAt != 0, "INVALID_BURN_STATE");

            // FIX: multiplier from the FIXED burnStartAt; delta from the SEPARATE
            //      lastBurnClaimAt. The multiplier reference is never reset.
            uint256 elapsedBurn = block.timestamp - uint256(s.burnStartAt);
            uint256 deltaBurn = block.timestamp - uint256(s.lastBurnClaimAt);
            if (deltaBurn == 0) return 0;

            uint256 mBurn = _multiplier(elapsedBurn);
            amount =
                (rewardRatePerSecond * deltaBurn * mBurn * burnBonusBps) /
                (ONE * MAX_BPS);

            if (amount == 0) return 0;

            // Reset ONLY the delta reference; burnStartAt is preserved.
            s.lastBurnClaimAt = uint64(block.timestamp);

            rewards.mint(msg.sender, amount);
            emit BurnRewardClaimed(msg.sender, tokenId, amount);
            return amount;
        }
        return 0;
    }

    function claim(uint256 tokenId) external returns (uint256) {
        return _claim(tokenId);
    }

    function seedBurnStake(uint256 tokenId, address stakeOwner, uint64 burnStartAt_, uint64 lastBurnClaimAt_)
        external
    {
        Stake storage s = stakes[tokenId];
        s.owner = stakeOwner;
        s.burned = true;
        s.burnStartAt = burnStartAt_;
        s.lastBurnClaimAt = lastBurnClaimAt_;
    }

    function setBurnStartAt(uint256 tokenId, uint64 v) external {
        stakes[tokenId].burnStartAt = v;
    }

    function setLastBurnClaimAt(uint256 tokenId, uint64 v) external {
        stakes[tokenId].lastBurnClaimAt = v;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver.
//
// Two identical burn stakers over the same duration T:
//   A claims ONCE at T          -> single claim sees the full-duration multiplier.
//   B claims once per day        -> every claim resets burnedAt, pinning the
//                                   multiplier at ~mult(1 day).
// Harm: minted(B) << minted(A). The shortfall is recorded on a marker at the SINK.
//
// Negative control: the same two schedules on the FIXED contract. The single
// claim is unchanged, but the frequent claimer is restored to ~81% of the
// baseline (the residual gap is the ordinary claim-early continuous-accrual
// penalty shared by normal staking) — proving the loss came from the multiplier
// RESET, not from claiming early.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant STAKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant DAY = 86400;
    uint256 internal constant T = 100 * DAY; // total burn duration
    uint256 internal constant N = 100; // B claims once per day

    // results (read by the driver)
    uint256 public aBuggy; // single-claim total (buggy)
    uint256 public bBuggy; // frequent-claim total (buggy)
    uint256 public aFixed; // single-claim total (fixed)
    uint256 public bFixed; // frequent-claim total (fixed)
    uint256 public shortfallBuggy; // aBuggy - bBuggy (lost burn rewards, the harm)
    uint256 public shortfallFixed; // aFixed - bFixed (residual claim-early penalty)
    uint256 public recoveredByFix; // bFixed - bBuggy (loss recovered by the fix)

    address public markerAddr;
    address public vulnAddr;
    uint256 public sinkMarker;

    function run() external payable {
        uint256 nowTs = block.timestamp;
        require(nowTs > 2 * T, "warp the clock past 2*T before running");

        MiniRewards rBuggy = new MiniRewards();
        NFTStaking stBuggy = new NFTStaking(rBuggy);
        MiniRewards rFixed = new MiniRewards();
        NFTStakingFixed stFixed = new NFTStakingFixed(rFixed);
        MiniToken marker = new MiniToken("Lost Burn Rewards", "LOST-REWARD");

        vulnAddr = address(stBuggy);
        markerAddr = address(marker);

        // ── A (buggy): single claim over the whole duration T ──
        stBuggy.seedBurnStake(1, STAKER, uint64(nowTs - T));
        stBuggy.claim(1);
        aBuggy = rBuggy.totalMinted();

        // ── B (buggy): a claim every day; each claim resets burnedAt so every
        //    window is exactly 1 day and the multiplier is pinned at mult(1 day) ──
        uint256 beforeB = rBuggy.totalMinted();
        stBuggy.seedBurnStake(2, STAKER, uint64(nowTs - T));
        for (uint256 i = 0; i < N; i++) {
            // emulate: exactly DAY elapsed since the previous claim's reset
            stBuggy.setBurnedAt(2, uint64(nowTs - DAY));
            stBuggy.claim(2);
        }
        bBuggy = rBuggy.totalMinted() - beforeB;

        // ── A (fixed): single claim ──
        stFixed.seedBurnStake(1, STAKER, uint64(nowTs - T), uint64(nowTs - T));
        stFixed.claim(1);
        aFixed = rFixed.totalMinted();

        // ── B (fixed): a claim every day; the multiplier grows from the fixed
        //    burnStartAt (elapsed = i*DAY) while the delta window stays 1 day ──
        uint256 beforeBf = rFixed.totalMinted();
        stFixed.seedBurnStake(2, STAKER, uint64(nowTs - T), uint64(nowTs - T));
        for (uint256 i = 1; i <= N; i++) {
            // emulate claim i at time (t0 + i*DAY): elapsed = i*DAY, delta = DAY
            stFixed.setBurnStartAt(2, uint64(nowTs - i * DAY));
            stFixed.setLastBurnClaimAt(2, uint64(nowTs - DAY));
            stFixed.claim(2);
        }
        bFixed = rFixed.totalMinted() - beforeBf;

        // ── harm accounting ──
        require(bBuggy < aBuggy, "no underpayment reproduced");
        shortfallBuggy = aBuggy - bBuggy;
        shortfallFixed = aFixed >= bFixed ? aFixed - bFixed : 0;
        recoveredByFix = bFixed - bBuggy;

        // the fix recovers far more than the residual claim-early penalty, and the
        // shortfall shrinks by >3x — proving the reset is the dominant cause.
        require(recoveredByFix > shortfallFixed, "fix did not collapse the shortfall");
        require(shortfallFixed * 3 < shortfallBuggy, "shortfall did not shrink under the fix");

        // record the lost burn rewards at the SINK (measurable balance delta)
        marker.mint(SINK, shortfallBuggy);
        sinkMarker = marker.balanceOf(SINK);
    }
}
