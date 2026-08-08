// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-11: Segment-split geometric-mean borrow overstates fees (#63177)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: computeBorrows uses geometric mean of each tree segment; a
    taker range split across nodes sums segment borrows ≫ full-range borrow.
    Vulnerable computeBorrows gmTick line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal computeBorrows: borrow amounts from liq at geometric-mean tick.
library BorrowMath {
    /// @dev Toy mapping: amountX decreases as gmTick rises; amountY increases.
    /// Scaled so mid-range is small X/Y while extreme segments dominate one side.
    function amountsAtTick(int24 gmTick, uint256 liq) internal pure returns (uint256 x, uint256 y) {
        // Use absolute tick distance from 0 as price proxy
        // x ≈ liq * exp(-tick/k), y ≈ liq * exp(+tick/k) — piecewise linear toy:
        if (gmTick >= 0) {
            // high price: mostly Y
            uint256 t = uint256(uint24(gmTick));
            y = liq * (1e6 + t) / 1e6;
            x = liq * 1e6 / (1e6 + t);
        } else {
            uint256 t = uint256(uint24(-gmTick));
            x = liq * (1e6 + t) / 1e6;
            y = liq * 1e6 / (1e6 + t);
        }
    }

    /// @notice Source shape: Data.computeBorrows geometric mean of interval.
    function computeBorrows(int24 lowTick, int24 highTick, uint256 liq)
        internal
        pure
        returns (uint256 borrowX, uint256 borrowY)
    {
        // The tick of the geometric mean.
        int24 gmTick = lowTick + (highTick - lowTick) / 2; // @> VULN: per-segment GM — sum of segment borrows ≫ full-range borrow when range is tree-split
        // FIX: compute once on full original range, then split amounts by width
        return amountsAtTick(gmTick, liq);
    }
}

/// @dev Records taker liq either as one full range or as multiple segments.
contract BorrowLedger {
    uint256 public totalBorrowX;
    uint256 public totalBorrowY;

    function recordFullRange(int24 low, int24 high, uint256 liq) external {
        (uint256 x, uint256 y) = BorrowMath.computeBorrows(low, high, liq);
        totalBorrowX = x;
        totalBorrowY = y;
    }

    /// @dev Split into two halves (segment tree style) and sum segment borrows.
    function recordSplitRange(int24 low, int24 high, uint256 liq) external {
        int24 mid = low + (high - low) / 2;
        (uint256 x0, uint256 y0) = BorrowMath.computeBorrows(low, mid, liq);
        (uint256 x1, uint256 y1) = BorrowMath.computeBorrows(mid, high, liq);
        totalBorrowX = x0 + x1;
        totalBorrowY = y0 + y1;
    }

    function feeOn(uint256 rateX64) external view returns (uint256 feeX, uint256 feeY) {
        feeX = (totalBorrowX * rateX64) >> 64;
        feeY = (totalBorrowY * rateX64) >> 64;
    }
}

/// CREATE: full(1), split(2)
contract Exploit {
    BorrowLedger public fullRange;
    BorrowLedger public splitRange;

    uint256 public fullX;
    uint256 public splitX;
    uint256 public fullY;
    uint256 public splitY;
    uint256 public feeFullX;
    uint256 public feeSplitX;

    int24 constant LOW = -122880;
    int24 constant HIGH = 245760;
    uint256 constant LIQ = 1e18;

    constructor() {
        fullRange = new BorrowLedger(); // 1
        splitRange = new BorrowLedger(); // 2
    }

    function run() external {
        // Expected: single GM at mid of full range
        fullRange.recordFullRange(LOW, HIGH, LIQ);
        // Buggy storage path: two segments, each with own GM
        splitRange.recordSplitRange(LOW, HIGH, LIQ);

        fullX = fullRange.totalBorrowX();
        fullY = fullRange.totalBorrowY();
        splitX = splitRange.totalBorrowX();
        splitY = splitRange.totalBorrowY();

        // Sum of segment borrows strictly greater (inflation)
        require(splitX + splitY > fullX + fullY, "split inflates total borrow notionals");
        require(splitX > fullX || splitY > fullY, "at least one side inflated");

        // 10% rate
        uint256 rate = (uint256(1) << 64) / 10;
        (feeFullX,) = fullRange.feeOn(rate);
        (feeSplitX,) = splitRange.feeOn(rate);

        // Harm: taker overpays fees vs full-range expectation
        require(feeSplitX > feeFullX, "taker fee X higher on split");
        // With extreme asymmetric GMs, inflation is large (report ~200×)
        uint256 sumFull = fullX + fullY;
        uint256 sumSplit = splitX + splitY;
        require(sumSplit > sumFull * 2, "material overstatement of borrow base");
    }
}
