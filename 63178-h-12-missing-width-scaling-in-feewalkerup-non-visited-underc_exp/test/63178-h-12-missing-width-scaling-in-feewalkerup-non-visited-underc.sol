// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Ammplify finding 63178 (H-12):
// "Missing width scaling in FeeWalker.up (non-visited) undercredits compounding
//  maker fees".
//
// In FeeWalker.up, when a node is charged via the PROPAGATION (non-visited) path,
// the compounding-maker quantity is computed as `mLiq - ncLiq` WITHOUT multiplying
// by `key.width()`. The per-column maker rate (colMakerXRateX128) is per
// column-liquidity and IS width-scaled, so the applied compounding quantity must
// also be width-scaled. The visited path correctly uses `width * (mLiq - ncLiq)`.
//
// Consequently a compounding maker whose fees accrue through the non-visited path
// is credited only 1/width of the fees it actually earned. For a width-8 node the
// maker is credited ~12.5% and ~87.5% of the earned compounding fee is never
// credited (stranded, effectively unclaimable).
//
// The repos (sherlock-audit/2025-09-ammplify and itos-finance/Ammplify) are both
// deleted (404). The vulnerable arithmetic is reproduced VERBATIM from the finding;
// FullMath.mulX128 (a Q128.128 multiply == mulDiv by 2**128) and add128Fees
// (a saturating 128-bit add) are minimal faithful doubles of standard itos helpers.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for itos FullMath.mulX128:
///      returns floor(a * b / 2**128) (a Q128.128 fixed-point multiply).
///      roundUp adds 1 when the discarded low-128 bits are non-zero.
///      Test values are bounded so the 256-bit product never overflows.
library FullMath {
    function mulX128(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        uint256 prod = a * b;
        res = prod >> 128;
        if (roundUp && (prod & type(uint128).max) != 0) {
            res += 1;
        }
    }
}

/// @dev Per-node liquidity split used by the fee walker.
struct Liq {
    uint256 mLiq; // total maker liquidity
    uint256 ncLiq; // non-compounding maker liquidity
}

/// @dev Per-node fee accumulators. xCFees/yCFees are the compounding-maker fee
///      accumulators later paid out directly (no downstream width normalization).
struct Fees {
    uint256 takerXFeesPerLiqX128;
    uint256 takerYFeesPerLiqX128;
    uint256 makerXFeesPerLiqX128;
    uint256 makerYFeesPerLiqX128;
    uint256 xCFees;
    uint256 yCFees;
}

struct Node {
    Fees fees;
    Liq liq;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: the non-visited crediting block from Fee.sol L249-L267
// is embedded VERBATIM. `compoundingLiq` omits the `* key.width()` factor.
// ─────────────────────────────────────────────────────────────────────────────
contract FeeWalker {
    /// @dev saturating 128-bit fee add (faithful minimal double for add128Fees).
    ///      `data` and `isX` are carried through to match the real signature; the
    ///      real helper uses them for protocol-fee accounting, irrelevant to the bug.
    function add128Fees(uint256 base, uint256 addend, uint256 /*data*/, bool /*isX*/)
        internal
        pure
        returns (uint256)
    {
        uint256 sum = base + addend;
        if (sum > type(uint128).max) return type(uint128).max;
        return sum;
    }

    /// @notice Faithful embedding of the non-visited (propagation) crediting path.
    ///         `width` is available (as key.width() is in the real code) but the
    ///         non-visited path never applies it — that is the bug.
    function up(
        Node memory node,
        uint256 width,
        uint256 colTakerXRateX128,
        uint256 colTakerYRateX128,
        uint256 colMakerXRateX128,
        uint256 colMakerYRateX128,
        uint256 data
    ) public pure returns (Node memory) {
        width; // available via key.width() in the real code; unused on this path (the defect)
        // ─── VERBATIM non-visited crediting block (Ammplify Fee.sol L249-L267) ───
        // We charge/pay our own fees.
        node.fees.takerXFeesPerLiqX128 += colTakerXRateX128;
        node.fees.takerYFeesPerLiqX128 += colTakerYRateX128;
        node.fees.makerXFeesPerLiqX128 += colMakerXRateX128;
        node.fees.makerYFeesPerLiqX128 += colMakerYRateX128;
        // We round down to avoid overpaying dust.
        uint256 compoundingLiq = node.liq.mLiq - node.liq.ncLiq; // @> missing `* key.width()`: compounding maker fees undercredited by a factor of width on non-visited nodes
        node.fees.xCFees = add128Fees(
            node.fees.xCFees,
            FullMath.mulX128(colMakerXRateX128, compoundingLiq, false),
            data,
            true
        );
        node.fees.yCFees = add128Fees(
            node.fees.yCFees,
            FullMath.mulX128(colMakerYRateX128, compoundingLiq, false),
            data,
            false
        );
        // ────────────────────────────────────────────────────────────────────────
        return node;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): the non-visited path applies the visited
// path's width scaling — `compoundingLiq = width * (mLiq - ncLiq)`.
// ─────────────────────────────────────────────────────────────────────────────
contract FeeWalkerFixed {
    function add128Fees(uint256 base, uint256 addend, uint256 /*data*/, bool /*isX*/)
        internal
        pure
        returns (uint256)
    {
        uint256 sum = base + addend;
        if (sum > type(uint128).max) return type(uint128).max;
        return sum;
    }

    function up(
        Node memory node,
        uint256 width,
        uint256 colTakerXRateX128,
        uint256 colTakerYRateX128,
        uint256 colMakerXRateX128,
        uint256 colMakerYRateX128,
        uint256 data
    ) public pure returns (Node memory) {
        node.fees.takerXFeesPerLiqX128 += colTakerXRateX128;
        node.fees.takerYFeesPerLiqX128 += colTakerYRateX128;
        node.fees.makerXFeesPerLiqX128 += colMakerXRateX128;
        node.fees.makerYFeesPerLiqX128 += colMakerYRateX128;
        // FIX: width-scale the compounding quantity to match the width-scaled rate,
        //      identical to the visited path (Fee.sol L418-L424).
        uint256 compoundingLiq = width * (node.liq.mLiq - node.liq.ncLiq);
        node.fees.xCFees = add128Fees(
            node.fees.xCFees,
            FullMath.mulX128(colMakerXRateX128, compoundingLiq, false),
            data,
            true
        );
        node.fees.yCFees = add128Fees(
            node.fees.yCFees,
            FullMath.mulX128(colMakerYRateX128, compoundingLiq, false),
            data,
            false
        );
        return node;
    }
}

/// @dev Minimal ERC20 double. `feeToken` is the real maker-fee pool paid out on
///      claim; `marker` records the harm magnitude at the SINK.
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: charge one width-8 node's compounding maker via the buggy
// non-visited path, then via the fixed path. The buggy credit is exactly 1/width
// of the correct credit; the ~87.5% shortfall is stranded/unclaimable and
// recorded on a LOST-FEE marker token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant MAKER = 0x1111111111111111111111111111111111111111;

    // Node parameters: width-8 node, compounding liquidity base = mLiq - ncLiq = 1000.
    uint256 internal constant WIDTH = 8;
    uint256 internal constant M_LIQ = 1200;
    uint256 internal constant NC_LIQ = 200; // base = 1000
    // colMakerXRateX128 = 1e15 (0.001 fee-token per unit column-liq) in Q128.128.
    uint256 internal constant RATE_REAL = 1e15;

    // Deployed doubles (created in the constructor, fixed nonce order).
    MiniToken public feeToken;
    FeeWalker public feeWalker;
    FeeWalkerFixed public feeWalkerFixed;
    MiniToken public marker;

    // Exposed results.
    uint256 public buggyXCFees;
    uint256 public correctXCFees;
    uint256 public shortfall;
    uint256 public makerCredited;
    uint256 public strandedInPool;
    uint256 public sinkMarkerBalance;
    address public feeWalkerAddr;
    address public feeWalkerFixedAddr;
    address public markerAddr;

    constructor() {
        feeToken = new MiniToken("Maker Fee", "MKF"); // nonce 1
        feeWalker = new FeeWalker(); // nonce 2
        feeWalkerFixed = new FeeWalkerFixed(); // nonce 3
        marker = new MiniToken("Lost Fee", "LOST-FEE"); // nonce 4 (LAST)

        feeWalkerAddr = address(feeWalker);
        feeWalkerFixedAddr = address(feeWalkerFixed);
        markerAddr = address(marker);
    }

    function run() external payable {
        uint256 rateX128 = RATE_REAL * (uint256(1) << 128);

        // Identical starting node for both the buggy and fixed walk.
        Node memory node;
        node.liq = Liq({mLiq: M_LIQ, ncLiq: NC_LIQ});

        // --- BUGGY non-visited path (missing * width): credits only base * rate ---
        Node memory buggyNode = feeWalker.up(node, WIDTH, 0, 0, rateX128, rateX128, 0);
        buggyXCFees = buggyNode.fees.xCFees; // = 1000 * 1e15 = 1 ether

        // --- FIXED path (width-scaled): credits width * base * rate ---
        Node memory fixedNode = feeWalkerFixed.up(node, WIDTH, 0, 0, rateX128, rateX128, 0);
        correctXCFees = fixedNode.fees.xCFees; // = 8 * 1000 * 1e15 = 8 ether

        // The maker actually earned `correctXCFees` of fees; fund the pool with it.
        feeToken.mint(address(this), correctXCFees);

        // xCFees is paid out directly (no downstream width normalization), so the
        // maker can only claim the under-credited buggy amount.
        makerCredited = buggyXCFees;
        feeToken.transfer(MAKER, makerCredited);

        // The remainder is stranded in the pool — the maker's earned fee it can
        // never claim because the accumulator was under-credited.
        shortfall = correctXCFees - buggyXCFees; // 7 ether = 87.5% of 8 ether
        strandedInPool = feeToken.balanceOf(address(this));

        // Record the lost (unclaimable) fee magnitude at the SINK.
        marker.mint(SINK, shortfall);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // Harm invariants: buggy credit is exactly 1/width of the correct credit,
        // and the stranded, unclaimable shortfall equals the recorded marker.
        require(buggyXCFees == correctXCFees / WIDTH, "not 1/width under-credit");
        require(strandedInPool == shortfall, "pool did not strand the shortfall");
        require(sinkMarkerBalance == shortfall, "marker mismatch");
    }
}
