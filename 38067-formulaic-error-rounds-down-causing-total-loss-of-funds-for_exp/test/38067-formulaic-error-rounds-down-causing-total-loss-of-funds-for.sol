// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tadle — Formulaic error rounds down, causing total loss of funds for
    bid takers during abort (Codehawks, inzinko, finding #38067)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    depositAmount computation inside abortBidTaker is inlined VERBATIM (the
    numerator/denominator swap); the Exploit deploys a reduced PreMarkets +
    TokenManager, wires up one aborted Bid-offer stock, and shows the taker's
    refund rounds down to ZERO instead of the correct proportional amount
    (no fork, no cheatcodes).

    Root cause: abortBidTaker computes
        depositAmount = stockInfo.points.mulDiv(preOfferInfo.points, preOfferInfo.amount, Floor)
    i.e. (purchasedPoints * totalPoints) / totalAmount — but it should be
        depositAmount = stockInfo.points.mulDiv(preOfferInfo.amount, preOfferInfo.points, Floor)
    i.e. (purchasedPoints * totalAmount) / totalPoints. Because totalAmount is
    typically a large 1e18-scale token amount, the swapped formula's numerator
    (purchasedPoints * totalPoints, both small integers) is dwarfed by the huge
    denominator (totalAmount) and integer division floors the result to zero —
    a total loss of the taker's refund.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @notice Minimal floor-division mulDiv, matching the finding's use of
///         OpenZeppelin Math.mulDiv(x, y, denominator, Math.Rounding.Floor).
library MathLib {
    enum Rounding {
        Floor,
        Ceil
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding /*rounding*/ ) internal pure returns (uint256) {
        return (x * y) / denominator; // Floor == plain integer division
    }
}

enum OfferType {
    Ask,
    Bid
}
enum AbortOfferStatus {
    Initialized,
    Aborted
}

struct OfferInfo {
    uint256 points; // total points in the offer (preOfferInfo.points)
    uint256 amount; // total token amount backing the offer (preOfferInfo.amount)
    uint256 collateralRate;
    OfferType offerType;
    AbortOfferStatus abortOfferStatus;
}

struct StockInfo {
    address authority; // the taker who holds this settlement stock
    uint256 points; // points purchased by this taker (stockInfo.points)
    address preOffer;
    uint8 stockStatus; // 0 = Initialized, 1 = Finished
}

/// @notice Mirrors OfferLibraries.getDepositAmount's Bid-path behaviour used by
///         abortBidTaker: for a Bid offer the transfer amount equals the deposit
///         amount directly (no collateral-rate scaling — that only applies to
///         the Ask path, out of scope for this reduction).
library OfferLibraries {
    uint256 internal constant COLLATERAL_RATE_DECIMAL_SCALER = 1e4;

    function getDepositAmount(OfferType offerType, uint256 collateralRate, uint256 amount, bool, MathLib.Rounding rounding)
        internal
        pure
        returns (uint256 transferAmount)
    {
        if (offerType == OfferType.Ask) {
            transferAmount = MathLib.mulDiv(amount, collateralRate, COLLATERAL_RATE_DECIMAL_SCALER, rounding);
        } else {
            transferAmount = amount;
        }
    }
}

/// @notice Credits a taker's aborted-bid refund into an internal ledger, mirroring
///         TokenManager.addTokenBalance(TokenBalanceType.MakerRefund, ...).
contract TokenManager {
    mapping(address => mapping(address => uint256)) public makerRefundBalance; // account -> token -> amount

    function addTokenBalance_MakerRefund(address account, address token, uint256 amount) external {
        makerRefundBalance[account][token] += amount;
    }
}

/// @notice Reduced PreMarkets. A `setup()` scaffolding function replaces the real
///         createOffer/createTaker/closeOffer/abortAskOffer wiring so the vulnerable
///         abortBidTaker formula can be exercised directly and deterministically.
contract PreMarkets {
    using MathLib for uint256;

    TokenManager public tokenManager;
    address public token;

    mapping(address => StockInfo) public stockInfoMap;
    mapping(address => OfferInfo) public offerInfoMap;

    error Unauthorized();
    error InvalidStockStatus();
    error InvalidAbortOfferStatus();

    constructor(TokenManager _tm, address _token) {
        tokenManager = _tm;
        token = _token;
    }

    /// @dev Test scaffolding only — wires up one already-aborted Bid-offer
    ///      settlement stock, mirroring what createOffer + createTaker + a
    ///      preceding abortAskOffer produce in the real system.
    function setup(address _stock, address _offer, address _taker, uint256 _stockPoints, uint256 _offerPoints, uint256 _offerAmount)
        external
    {
        stockInfoMap[_stock] = StockInfo({authority: _taker, points: _stockPoints, preOffer: _offer, stockStatus: 0});
        offerInfoMap[_offer] = OfferInfo({
            points: _offerPoints,
            amount: _offerAmount,
            collateralRate: 12000,
            offerType: OfferType.Bid,
            abortOfferStatus: AbortOfferStatus.Aborted
        });
    }

    /**
     * @notice abort bid taker (VULNERABLE)
     * @param _stock stock address
     * @param _offer offer address
     * @notice Only offer owner can abort bid taker
     * @dev Only offer abort status is aborted can be aborted
     * @dev Update stock authority refund amount
     */
    function abortBidTaker(address _stock, address _offer) external {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        OfferInfo storage preOfferInfo = offerInfoMap[_offer];

        if (stockInfo.authority != msg.sender) {
            revert Unauthorized();
        }
        if (stockInfo.stockStatus != 0) {
            revert InvalidStockStatus();
        }
        if (preOfferInfo.abortOfferStatus != AbortOfferStatus.Aborted) {
            revert InvalidAbortOfferStatus();
        }

        uint256 depositAmount = stockInfo.points.mulDiv(
            preOfferInfo.points,
            preOfferInfo.amount, // @> VULN: numerator/denominator swapped — should be (preOfferInfo.amount, preOfferInfo.points)
            MathLib.Rounding.Floor
        );
        // FIX: stockInfo.points.mulDiv(preOfferInfo.amount, preOfferInfo.points, Math.Rounding.Floor);

        uint256 transferAmount =
            OfferLibraries.getDepositAmount(preOfferInfo.offerType, preOfferInfo.collateralRate, depositAmount, false, MathLib.Rounding.Floor);

        tokenManager.addTokenBalance_MakerRefund(msg.sender, token, transferAmount);

        stockInfo.stockStatus = 1;
    }

    /// @notice The FIXED version (numerator/denominator corrected), for the control test.
    function abortBidTakerFixed(address _stock, address _offer) external {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        OfferInfo storage preOfferInfo = offerInfoMap[_offer];

        if (stockInfo.authority != msg.sender) {
            revert Unauthorized();
        }
        if (stockInfo.stockStatus != 0) {
            revert InvalidStockStatus();
        }
        if (preOfferInfo.abortOfferStatus != AbortOfferStatus.Aborted) {
            revert InvalidAbortOfferStatus();
        }

        uint256 depositAmount = stockInfo.points.mulDiv(preOfferInfo.amount, preOfferInfo.points, MathLib.Rounding.Floor);

        uint256 transferAmount =
            OfferLibraries.getDepositAmount(preOfferInfo.offerType, preOfferInfo.collateralRate, depositAmount, false, MathLib.Rounding.Floor);

        tokenManager.addTokenBalance_MakerRefund(msg.sender, token, transferAmount);

        stockInfo.stockStatus = 1;
    }
}

/// @notice Demonstrates the total loss of funds: the SAME taker aborts two
///         economically-identical stocks — one through the buggy path, one
///         through the fixed path — and the buggy path's refund is zero.
contract Exploit {
    MockToken public token;
    TokenManager public tokenManager;
    PreMarkets public preMarkets;

    address public stockAddr = address(0xAAA2);
    address public offerAddr = address(0xBBB2);
    address public fixedStockAddr = address(0xCCC2);
    address public fixedOfferAddr = address(0xDDD2);

    uint256 public constant TOTAL_POINTS = 1000;
    uint256 public constant PURCHASED_POINTS = 500;
    uint256 public constant TOKEN_AMOUNT = 1 ether;
    // Correct refund per the fixed formula: purchasedPoints * tokenAmount / totalPoints
    uint256 public constant EXPECTED_REFUND = (PURCHASED_POINTS * TOKEN_AMOUNT) / TOTAL_POINTS; // 0.5 ether

    constructor() {
        token = new MockToken();
        tokenManager = new TokenManager();
        preMarkets = new PreMarkets(tokenManager, address(token));

        preMarkets.setup(stockAddr, offerAddr, address(this), PURCHASED_POINTS, TOTAL_POINTS, TOKEN_AMOUNT);
        preMarkets.setup(fixedStockAddr, fixedOfferAddr, address(this), PURCHASED_POINTS, TOTAL_POINTS, TOKEN_AMOUNT);
    }

    function run() external {
        // === buggy path: taker aborts, expecting their proportional 0.5 token refund ===
        preMarkets.abortBidTaker(stockAddr, offerAddr);
        uint256 buggyRefund = tokenManager.makerRefundBalance(address(this), address(token));
        require(buggyRefund == 0, "harm not demonstrated: buggy formula should round the refund to zero");

        // === fixed path: the SAME taker, same economics, correct formula ===
        preMarkets.abortBidTakerFixed(fixedStockAddr, fixedOfferAddr);
        uint256 totalAfterFixed = tokenManager.makerRefundBalance(address(this), address(token));
        uint256 correctRefund = totalAfterFixed - buggyRefund;

        // HARM: the taker's fair-share refund (0.5 token) is entirely lost through the
        // buggy path, while the identical economics correctly refund 0.5 token when fixed.
        require(correctRefund == EXPECTED_REFUND, "expected fixed formula to correctly refund 0.5 token");
    }
}
