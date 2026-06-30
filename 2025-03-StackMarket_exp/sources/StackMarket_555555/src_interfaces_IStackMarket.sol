// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IStackMarket {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    // The address of the newly created token
    event TokenCreated(
        address indexed tokenContract,
        // The underlying account that the token represents
        address indexed owner,
        // The account that first created the token.
        address indexed creator
    );

    event TokensPurchased(
        address indexed buyer, address indexed tokenContract, uint256 ethAmount, uint256 tokenAmount, bool wasGraduated
    );

    event TokensSold(
        address indexed seller, address indexed tokenContract, uint256 ethAmount, uint256 tokenAmount, bool isGraduated
    );

    event TokenGraduated(
        address indexed tokenContract, address indexed owner, uint256 ethLiquidity, uint256 tokenLiquidity
    );

    event LiquidityAdditionAttempted(
        address indexed tokenContract, uint256 ethAmount, uint256 tokenAmount, string reason
    );

    event InitialSwapFailed(
        address indexed pool, uint160 currentSqrtPriceX96, uint160 targetSqrtPriceX96, string reason
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StackMarket__InvalidBaseName();
    error StackMarket__InvalidCreator();
    error StackMarket__InsufficientPayment();
    error StackMarket__InsufficientBalance();
    error StackMarket__InsufficientAllowance();
    error StackMarket__InsufficientLiquidity();
    error StackMarket__RecipientIsNull();
    error StackMarket__TokenNotFound();
    error StackMarket__TradeTooSmall();
    error StackMarket__InsufficientEthForGraduation();
    error StackMarket__TokenAlreadyExists();
    error StackMarket__Graduated();

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct AccountInfo {
        uint96 ownerDistribution; // Fits within 96 bits (enough for token amounts)
        uint96 ethLiquidity; // Fits within 96 bits
        uint64 vestingStart; // Timestamp fits in 64 bits
        bool graduated; // 1 bit
        address pool; // 160 bits
    }

    struct MarketData {
        address owner;
        address token;
        address uniswapPool;
        uint256 bondingCurveProgression;
        uint256 bondingCurvePrice;
        uint256 marketEthLiquidity;
        uint256 distributedToOwner;
        uint256 vestingStartedAt;
        uint256 uniswapPoolPriceX96;
        uint16 bondingCurveProgressionPercent;
        bool isGraduated;
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function create(address account) external payable returns (address);
    function create(string calldata name, string calldata symbol, address account) external payable returns (address);
    function create(string calldata label, address account) external payable returns (address);
    function buy(address account, uint256 minTokens, uint160 sqrtPriceLimitX96) external payable;
    function buyFor(address account, uint256 minTokens, address recipient, uint160 sqrtPriceLimitX96)
        external
        payable;
    function sell(address account, uint256 tokenAmount, uint256 minEth, uint160 sqrtPriceLimitX96) external;
    function sellTo(address recipient, address account, uint256 tokenAmount, uint256 minEth, uint160 sqrtPriceLimitX96)
        external;
    function setFeeRecipient(address _feeRecipient) external;

    function getEthBuyQuote(address account, uint256 ethAmount) external view returns (uint256);
    function getTokenBuyQuote(address account, uint256 tokenAmount) external view returns (uint256);
    function getEthSellQuote(address account, uint256 ethAmount) external view returns (uint256);
    function getTokenSellQuote(address account, uint256 tokenAmount) external view returns (uint256);
    function getAccountToken(address account) external view returns (address payable);
    function getMarketData(address account) external view returns (MarketData memory);
    function getAccountPool(address account) external view returns (address);
    function isGraduated(address account) external view returns (bool);
    function getOwnerDistribution(address account) external view returns (uint256);
    function getVestingStart(address account) external view returns (uint256);
    function marketBalance(address account) external view returns (uint256);
    function ethLiquidity(address account) external view returns (uint256);
    function calculateFees(uint256 tradeSize, address referrer)
        external
        pure
        returns (uint256 protocolFee, uint256 ownerFee, uint256 referralFee);
    function distributeOwnerTokens(address account) external;
    function getBondingCurveProgressionPercent(address account) external view returns (uint256);
    function getBondingCurveProgression(address account) external view returns (uint256);
}
