// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20Upgradeable, SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../tokens/interfaces/IUSDP.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "../peripherals/interfaces/ITimelockTemp.sol";

contract Vault is ReentrancyGuardUpgradeable, IVault {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDP_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isLeverageEnabled;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdp;
    address public override collateralToken;
    address public override gov;

    uint256 public override whitelistedTokenCount;

    uint256 public override maxLeverage;

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints;
    uint256 public override mintBurnFeeBasisPoints;
    uint256 public override marginFeeBasisPoints;

    uint256 public override minProfitTime;
    bool public override hasDynamicFees;

    uint256 public override fundingInterval;
    uint256 public override fundingRateFactor;

    bool public includeAmmPrice;
    bool public useSwapPricing;

    bool public override inManagerMode;
    bool public override inPrivateLiquidationMode;

    uint256 public override maxGasPrice;

    mapping(address => mapping(address => bool))
        public
        override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping(address => uint256) public override tokenBalances;

    // usdpAmount tracks the amount of USDP debt for collateral token
    uint256 public override usdpAmount;

    // maxUsdpAmount allows setting a max amount of USDP debt
    uint256 public override maxUsdpAmount;

    // poolAmount tracks the number of collateral token that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    uint256 public override poolAmount;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address => mapping(bool => uint256))
        public
        override reservedAmounts;

    // total reserved amount for open leverage positions
    uint256 public override totalReservedAmount;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address => mapping(bool => uint256))
        public
        override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address => mapping(bool => uint256))
        public
        override lastFundingTimes;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // feeReserve tracks the amount of trading fee
    uint256 public override feeReserve;
    // permanentPoolAmount tracks the amount of plp mint/burn fee which is used as permanent liquidity
    uint256 public override permanentPoolAmount;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override maxGlobalShortSizes;

    mapping(address => uint256) public override globalLongSizes;
    mapping(address => uint256) public override globalLongAveragePrices;
    mapping(address => uint256) public override maxGlobalLongSizes;

    mapping(uint256 => string) public errors;

    IVaultUtils public vaultUtils;

    event BuyUSDP(
        address account,
        uint256 tokenAmount,
        uint256 usdpAmount,
        uint256 feeBasisPoints
    );
    event SellUSDP(
        address account,
        uint256 usdpAmount,
        uint256 tokenAmount,
        uint256 feeBasisPoints
    );

    event IncreasePosition(
        bytes32 key,
        address account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(
        address indexed token,
        bool indexed isLong,
        uint256 fundingRate
    );
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectPermanentPoolAmount(uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(uint256 amount);
    event IncreasePoolAmount(uint256 amount);
    event DecreasePoolAmount(uint256 amount);
    event IncreaseUsdpAmount(uint256 amount);
    event DecreaseUsdpAmount(uint256 amount);
    event IncreaseReservedAmount(
        address indexed token,
        bool indexed isLong,
        uint256 amount
    );
    event DecreaseReservedAmount(
        address indexed token,
        bool indexed isLong,
        uint256 amount
    );

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract

    function initialize() public initializer {
        __ReentrancyGuard_init();

        gov = msg.sender;

        isLeverageEnabled = true;
        maxLeverage = 50 * 10000; // 50x
        taxBasisPoints = 50; // 0.5%
        mintBurnFeeBasisPoints = 30; // 0.3%
        marginFeeBasisPoints = 10; // 0.1%
        fundingInterval = 8 hours;
        includeAmmPrice = true;
    }

    function setParams(
        address _router,
        address _collateralToken,
        address _usdp,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 6);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 9);

        isInitialized = true;

        router = _router;
        collateralToken = _collateralToken;
        usdp = _usdp;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
    }

    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyGov();
        vaultUtils = _vaultUtils;
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(
        uint256 _errorCode,
        string calldata _error
    ) external override {
        require(
            msg.sender == errorController,
            "Vault: invalid errorController"
        );
        errors[_errorCode] = _error;
    }

    function allWhitelistedTokensLength()
        external
        view
        override
        returns (uint256)
    {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGovAdmin();
        inManagerMode = _inManagerMode;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(
        bool _inPrivateLiquidationMode
    ) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(
        address _liquidator,
        bool _isActive
    ) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setGov(address _gov) external {
        _onlyGov();
        _validateAddr(_gov);
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setMaxGlobalSize(
        address _token,
        uint256 _longAmount,
        uint256 _shortAmount
    ) external override {
        _onlyGov();

        maxGlobalLongSizes[_token] = _longAmount;
        maxGlobalShortSizes[_token] = _shortAmount;
    }

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 6);
        taxBasisPoints = _taxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor
    ) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 7);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 8);
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
    }

    function setMaxUsdpAmounts(uint256 _maxUsdpAmounts) external override {
        _onlyGov();

        maxUsdpAmount = _maxUsdpAmounts;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
    ) external override {
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount += 1;
            allWhitelistedTokens.push(_token);
        }

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        minProfitBasisPoints[_token] = _minProfitBps;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external {
        _onlyGov();
        require(
            _token != collateralToken,
            "Vault: Cannot clear collateralToken"
        );
        _validate(whitelistedTokens[_token], 9);
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete minProfitBasisPoints[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount -= 1;
    }

    function withdrawFees(
        address _receiver
    ) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserve;
        if (amount == 0) {
            return 0;
        }
        feeReserve = 0;
        _transferOut(amount, _receiver);
        return amount;
    }

    function withdrawTokens(address _receiver) external override {
        _onlyGovAdmin();

        poolAmount = 0;
        feeReserve = 0;
        totalReservedAmount = 0;
        usdpAmount = 0;
        permanentPoolAmount = 0;

        uint256 _balance = IERC20Upgradeable(collateralToken).balanceOf(
            address(this)
        );
        IERC20Upgradeable(collateralToken).safeTransfer(_receiver, _balance);
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdpAmount(uint256 _amount) external override {
        _onlyGov();

        uint256 _usdpAmount = usdpAmount;
        if (_amount > _usdpAmount) {
            _increaseUsdpAmount(_amount - _usdpAmount);
            return;
        }

        _decreaseUsdpAmount(_usdpAmount - _amount);
    }

    // deposit into the pool without minting USDP tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit() external override nonReentrant {
        uint256 tokenAmount = _transferIn(collateralToken);
        _validate(tokenAmount > 0, 11);
        _increasePoolAmount(tokenAmount);
        emit DirectPoolDeposit(tokenAmount);
    }

    function estimateUSDPOut(
        uint256 _amount
    ) external view override returns (uint256) {
        _validate(_amount > 0, 13);

        uint256 price = getMinPrice(collateralToken);
        uint256 _usdpAmount = (_amount * price) / PRICE_PRECISION;
        _usdpAmount = adjustForDecimals(_usdpAmount, collateralToken, usdp);

        if (_usdpAmount == 0) return 0;

        uint256 feeBasisPoints = vaultUtils.getBuyUsdpFeeBasisPoints(
            collateralToken,
            _usdpAmount
        );

        uint256 afterFeeAmount = (_amount *
            (BASIS_POINTS_DIVISOR - feeBasisPoints)) / BASIS_POINTS_DIVISOR;

        uint256 mintAmount = (afterFeeAmount * price) / PRICE_PRECISION;
        mintAmount = adjustForDecimals(mintAmount, collateralToken, usdp);

        return mintAmount;
    }

    function estimateTokenIn(
        uint256 _usdpAmount
    ) external view override returns (uint256) {
        _validate(_usdpAmount > 0, 16);

        uint256 price = getMinPrice(collateralToken);

        _usdpAmount = adjustForDecimals(_usdpAmount, usdp, collateralToken);

        uint256 amountAfterFees = (_usdpAmount * PRICE_PRECISION) / price;
        uint256 feeBasisPoints = vaultUtils.getBuyUsdpFeeBasisPoints(
            collateralToken,
            _usdpAmount
        );

        return
            (amountAfterFees * BASIS_POINTS_DIVISOR) /
            (BASIS_POINTS_DIVISOR - feeBasisPoints);
    }

    function buyUSDP(
        address _receiver
    ) external override nonReentrant returns (uint256) {
        revert("paused");
        _validateManager();
        _validateAddr(_receiver);

        address _collateralToken = collateralToken;
        useSwapPricing = true;

        uint256 tokenAmount = _transferIn(_collateralToken);
        _validate(tokenAmount > 0, 13);

        uint256 price = getMinPrice(_collateralToken);

        uint256 _usdpAmount = (tokenAmount * price) / PRICE_PRECISION;
        _usdpAmount = adjustForDecimals(_usdpAmount, _collateralToken, usdp);
        _validate(_usdpAmount > 0, 14);

        uint256 feeBasisPoints = vaultUtils.getBuyUsdpFeeBasisPoints(
            _collateralToken,
            _usdpAmount
        );
        uint256 amountAfterFees = _collectSwapFees(
            _collateralToken,
            tokenAmount,
            feeBasisPoints
        );
        uint256 mintAmount = (amountAfterFees * price) / PRICE_PRECISION;
        mintAmount = adjustForDecimals(mintAmount, _collateralToken, usdp);

        _increaseUsdpAmount(mintAmount);
        _increasePoolAmount(tokenAmount);

        IUSDP(usdp).mint(_receiver, mintAmount);

        emit BuyUSDP(_receiver, tokenAmount, mintAmount, feeBasisPoints);

        useSwapPricing = false;
        return mintAmount;
    }

    function sellUSDP(
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        useSwapPricing = true;

        uint256 _usdpAmount = _transferIn(usdp);
        _validate(_usdpAmount > 0, 16);

        address _collateralToken = collateralToken;

        uint256 redemptionAmount = getRedemptionAmount(_usdpAmount);

        _validate(redemptionAmount > 0, 17);

        uint256 feeBasisPoints = vaultUtils.getSellUsdpFeeBasisPoints(
            _collateralToken,
            _usdpAmount
        );
        uint256 amountOut = _collectSwapFees(
            _collateralToken,
            redemptionAmount,
            feeBasisPoints
        );

        _decreaseUsdpAmount(_usdpAmount);

        require(
            permanentPoolAmount + amountOut <= poolAmount,
            "Vault: poolAmount exceeded"
        );
        _decreasePoolAmount(amountOut);

        IUSDP(usdp).burn(address(this), _usdpAmount);

        // the _transferIn call increased the value of tokenBalances[usdp]
        // usually decreases in token balances are synced by calling _transferOut
        // however, for usdp, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdp);

        _validate(amountOut > 0, 18);

        _transferOut(amountOut, _receiver);

        emit SellUSDP(_receiver, _usdpAmount, amountOut, feeBasisPoints);

        useSwapPricing = false;
        return amountOut;
    }

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override nonReentrant {
        revert("paused");
        _validate(isLeverageEnabled, 24);
        _validateGasPrice();
        _validateRouter(_account);
        _validateTokens(_indexToken, _isLong);
        address _collateralToken = collateralToken;

        vaultUtils.validateIncreasePosition(
            _account,
            _indexToken,
            _sizeDelta,
            _isLong
        );

        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 price = _isLong
            ? getMaxPrice(_indexToken)
            : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }

        uint256 fee = _collectMarginFees(
            _account,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(
            _collateralToken,
            collateralDelta
        );

        position.collateral = position.collateral + collateralDeltaUsd;

        _validate(position.collateral >= fee, 25);

        position.collateral -= fee;
        position.entryFundingRate = getEntryFundingRate(_indexToken, _isLong);
        position.size += _sizeDelta;
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 26);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _indexToken, _isLong, true);

        // reserve token to pay profits on the position
        uint256 reserveDelta = usdToCollateralTokenMax(_sizeDelta);
        position.reserveAmount += reserveDelta;
        _increaseReservedAmount(_indexToken, _isLong, reserveDelta);

        if (_isLong) {
            if (globalLongSizes[_indexToken] == 0) {
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[
                    _indexToken
                ] = getNextGlobalLongAveragePrice(
                    _indexToken,
                    price,
                    _sizeDelta
                );
            }

            _increaseGlobalLongSize(_indexToken, _sizeDelta);
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[
                    _indexToken
                ] = getNextGlobalShortAveragePrice(
                    _indexToken,
                    price,
                    _sizeDelta
                );
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(
            key,
            _account,
            _indexToken,
            collateralDeltaUsd,
            _sizeDelta,
            _isLong,
            price,
            fee
        );
        emit UpdatePosition(
            key,
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return
            _decreasePosition(
                _account,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver
            );
    }

    function _decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        _validateAddr(_receiver);
        vaultUtils.validateDecreasePosition(
            _account,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];
        _validate(position.size > 0, 27);
        _validate(position.size >= _sizeDelta, 28);
        _validate(position.collateral >= _collateralDelta, 29);

        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * _sizeDelta) /
                position.size;
            position.reserveAmount -= reserveDelta;
            _decreaseReservedAmount(_indexToken, _isLong, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(
                _indexToken,
                _isLong
            );
            position.size -= _sizeDelta;

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _indexToken, _isLong, true);

            uint256 price = _isLong
                ? getMinPrice(_indexToken)
                : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key,
                _account,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - usdOutAfterFee
            );
            emit UpdatePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                price
            );
        } else {
            uint256 price = _isLong
                ? getMinPrice(_indexToken)
                : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key,
                _account,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - usdOutAfterFee
            );
            emit ClosePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl
            );

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        } else {
            _decreaseGlobalLongSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            uint256 amountOutAfterFees = usdToCollateralTokenMin(
                usdOutAfterFee
            );
            _transferOut(amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function liquidatePosition(
        address _account,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external override nonReentrant {
        revert("paused");
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 30);
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        includeAmmPrice = false;

        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.size > 0, 31);

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(
            _account,
            _indexToken,
            _isLong,
            false
        );
        _validate(liquidationState != 0, 32);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(
                _account,
                _indexToken,
                0,
                position.size,
                _isLong,
                _account
            );
            includeAmmPrice = true;
            return;
        }

        uint256 feeTokens = usdToCollateralTokenMin(marginFees);
        feeReserve += feeTokens;
        emit CollectMarginFees(marginFees, feeTokens);

        _decreaseReservedAmount(_indexToken, _isLong, position.reserveAmount);

        uint256 markPrice = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        emit LiquidatePosition(
            key,
            _account,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );

        if (marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - marginFees;
            _increasePoolAmount(usdToCollateralTokenMin(remainingCollateral));
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        } else {
            _decreaseGlobalLongSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(usdToCollateralTokenMin(liquidationFeeUsd));
        _transferOut(usdToCollateralTokenMin(liquidationFeeUsd), _feeReceiver);

        includeAmmPrice = true;
    }

    // validateLiquidation returns (state, fees)
    function validateLiquidation(
        address _account,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view override returns (uint256, uint256) {
        return
            vaultUtils.validateLiquidation(
                _account,
                _indexToken,
                _isLong,
                _raise
            );
    }

    function getMaxPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IVaultPriceFeed(priceFeed).getPrice(
                _token,
                true,
                includeAmmPrice,
                useSwapPricing
            );
    }

    function getMinPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IVaultPriceFeed(priceFeed).getPrice(
                _token,
                false,
                includeAmmPrice,
                useSwapPricing
            );
    }

    function getRedemptionAmount(
        uint256 _usdpAmount
    ) public view override returns (uint256) {
        address _token = collateralToken;
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdpAmount * PRICE_PRECISION) / price;
        return adjustForDecimals(redemptionAmount, usdp, _token);
    }

    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdp
            ? USDP_DECIMALS
            : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdp
            ? USDP_DECIMALS
            : tokenDecimals[_tokenMul];
        return (_amount * (10 ** decimalsMul)) / (10 ** decimalsDiv);
    }

    function tokenToUsdMin(
        address _token,
        uint256 _tokenAmount
    ) public view override returns (uint256) {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return (_tokenAmount * price) / (10 ** decimals);
    }

    function usdToCollateralTokenMax(
        uint256 _usdAmount
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return
            usdToToken(
                collateralToken,
                _usdAmount,
                getMinPrice(collateralToken)
            );
    }

    function usdToCollateralTokenMin(
        uint256 _usdAmount
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return
            usdToToken(
                collateralToken,
                _usdAmount,
                getMaxPrice(collateralToken)
            );
    }

    function usdToToken(
        address _token,
        uint256 _usdAmount,
        uint256 _price
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = tokenDecimals[_token];
        return (_usdAmount * (10 ** decimals)) / _price;
    }

    function getPosition(
        address _account,
        address _indexToken,
        bool _isLong
    )
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0
            ? uint256(position.realisedPnl)
            : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getPositionKey(
        address _account,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _indexToken, _isLong));
    }

    function updateCumulativeFundingRate(
        address _indexToken,
        bool _isLong
    ) public {
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(_indexToken);
        if (!shouldUpdate) {
            return;
        }
        address indexToken = _indexToken;
        bool isLong = _isLong;

        if (lastFundingTimes[indexToken][isLong] == 0) {
            lastFundingTimes[indexToken][isLong] =
                (block.timestamp / fundingInterval) *
                fundingInterval;
            return;
        }

        if (
            lastFundingTimes[indexToken][isLong] + fundingInterval >
            block.timestamp
        ) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(indexToken, isLong);
        cumulativeFundingRates[indexToken][isLong] += fundingRate;
        lastFundingTimes[indexToken][isLong] =
            (block.timestamp / fundingInterval) *
            fundingInterval;

        emit UpdateFundingRate(
            indexToken,
            isLong,
            cumulativeFundingRates[indexToken][isLong]
        );
    }

    function getNextFundingRate(
        address _token,
        bool _isLong
    ) public view override returns (uint256) {
        if (
            lastFundingTimes[_token][_isLong] + fundingInterval >
            block.timestamp
        ) {
            return 0;
        }

        uint256 intervals = (block.timestamp -
            lastFundingTimes[_token][_isLong]) / fundingInterval;
        if (poolAmount == 0) {
            return 0;
        }

        return
            (fundingRateFactor * reservedAmounts[_token][_isLong] * intervals) /
            poolAmount;
    }

    function getUtilisation(
        address _token,
        bool _isLong
    ) public view returns (uint256) {
        if (poolAmount == 0) {
            return 0;
        }

        return
            (reservedAmounts[_token][_isLong] * FUNDING_RATE_PRECISION) /
            poolAmount;
    }

    function getPositionLeverage(
        address _account,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.collateral > 0, 33);
        return (position.size * BASIS_POINTS_DIVISOR) / position.collateral;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            _size,
            _averagePrice,
            _isLong,
            _lastIncreasedTime
        );
        uint256 nextSize = _size + _sizeDelta;
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize + delta : nextSize - delta;
        } else {
            divisor = hasProfit ? nextSize - delta : nextSize + delta;
        }
        return (_nextPrice * nextSize) / divisor;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice
            ? averagePrice - _nextPrice
            : _nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize - delta : nextSize + delta;

        return (_nextPrice * nextSize) / divisor;
    }

    function getNextGlobalLongAveragePrice(
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        uint256 size = globalLongSizes[_indexToken];
        uint256 averagePrice = globalLongAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice
            ? averagePrice - _nextPrice
            : _nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice < _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize + delta : nextSize - delta;

        return (_nextPrice * nextSize) / divisor;
    }

    function getGlobalShortDelta(
        address _token
    ) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) {
            return (false, 0);
        }

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice
            ? averagePrice - nextPrice
            : nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getPositionDelta(
        address _account,
        address _indexToken,
        bool _isLong
    ) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        return
            getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        _validate(_averagePrice > 0, 34);
        uint256 price = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price
            ? _averagePrice - price
            : price - _averagePrice;
        uint256 delta = (_size * priceDelta) / _averagePrice;

        bool hasProfit = _isLong
            ? price > _averagePrice
            : _averagePrice > price;

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + minProfitTime
            ? 0
            : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta * BASIS_POINTS_DIVISOR <= _size * minBps) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getEntryFundingRate(
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        return vaultUtils.getEntryFundingRate(_indexToken, _isLong);
    }

    function getFundingFee(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view returns (uint256) {
        return
            vaultUtils.getFundingFee(
                _account,
                _indexToken,
                _isLong,
                _size,
                _entryFundingRate
            );
    }

    function getPositionFee(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return
            vaultUtils.getPositionFee(
                _account,
                _indexToken,
                _isLong,
                _sizeDelta
            );
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    function getFeeBasisPoints(
        address _token,
        uint256 _usdpDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) public view override returns (uint256) {
        return
            vaultUtils.getFeeBasisPoints(
                _token,
                _usdpDelta,
                _feeBasisPoints,
                _taxBasisPoints,
                _increment
            );
    }

    function getTargetUsdpAmount() public view override returns (uint256) {
        return IERC20Upgradeable(usdp).totalSupply();
    }

    function _reduceCollateral(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(
            _account,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = (_sizeDelta * delta) / position.size;
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for positions
            uint256 tokenAmount = usdToCollateralTokenMin(adjustedDelta);
            _decreasePoolAmount(tokenAmount);
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            // transfer realised losses to the pool for positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            uint256 tokenAmount = usdToCollateralTokenMin(adjustedDelta);
            _increasePoolAmount(tokenAmount);

            position.realisedPnl -= int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut += _collateralDelta;
            position.collateral -= _collateralDelta;
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            position.collateral -= fee;
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(
        uint256 _size,
        uint256 _collateral
    ) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 35);
            return;
        }
        _validate(_size >= _collateral, 36);
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        if (msg.sender == router) {
            return;
        }
        _validate(approvedRouters[_account][msg.sender], 37);
    }

    function _validateTokens(address _indexToken, bool isLong) private view {
        _validate(whitelistedTokens[_indexToken], 9);
        if (!isLong) {
            _validate(!stableTokens[_indexToken], 38);
            _validate(shortableTokens[_indexToken], 39);
        }
    }

    function _collectSwapFees(
        address _token,
        uint256 _amount,
        uint256 _feeBasisPoints
    ) private returns (uint256) {
        uint256 afterFeeAmount = (_amount *
            (BASIS_POINTS_DIVISOR - _feeBasisPoints)) / BASIS_POINTS_DIVISOR;
        uint256 feeAmount = _amount - afterFeeAmount;
        permanentPoolAmount += feeAmount;
        emit CollectPermanentPoolAmount(
            tokenToUsdMin(_token, feeAmount),
            feeAmount
        );
        return afterFeeAmount;
    }

    function _collectMarginFees(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 feeUsd = getPositionFee(
            _account,
            _indexToken,
            _isLong,
            _sizeDelta
        );

        uint256 fundingFee = getFundingFee(
            _account,
            _indexToken,
            _isLong,
            _size,
            _entryFundingRate
        );
        feeUsd += fundingFee;

        uint256 feeTokens = usdToCollateralTokenMin(feeUsd);
        feeReserve += feeTokens;

        emit CollectMarginFees(feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20Upgradeable(_token).balanceOf(
            address(this)
        );
        tokenBalances[_token] = nextBalance;

        return nextBalance - prevBalance;
    }

    function _transferOut(uint256 _amount, address _receiver) private {
        _validateAddr(_receiver);
        address _token = collateralToken;
        IERC20Upgradeable(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20Upgradeable(_token).balanceOf(
            address(this)
        );
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20Upgradeable(_token).balanceOf(
            address(this)
        );
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(uint256 _amount) private {
        poolAmount += _amount;
        uint256 balance = IERC20Upgradeable(collateralToken).balanceOf(
            address(this)
        );
        _validate(poolAmount <= balance, 40);
        emit IncreasePoolAmount(_amount);
    }

    function _decreasePoolAmount(uint256 _amount) private {
        require(poolAmount >= _amount, "Vault: poolAmount exceeded");
        poolAmount -= _amount;
        _validate(totalReservedAmount <= poolAmount, 41);
        emit DecreasePoolAmount(_amount);
    }

    function _increaseUsdpAmount(uint256 _amount) private {
        usdpAmount += _amount;
        if (maxUsdpAmount != 0) {
            _validate(usdpAmount <= maxUsdpAmount, 42);
        }
        emit IncreaseUsdpAmount(_amount);
    }

    function _decreaseUsdpAmount(uint256 _amount) private {
        uint256 value = usdpAmount;
        // it is possible for the USDP debt to be less than zero
        // the USDP debt is capped to zero for this case
        if (value <= _amount) {
            usdpAmount = 0;
            emit DecreaseUsdpAmount(value);
            return;
        }
        usdpAmount = value - _amount;
        emit DecreaseUsdpAmount(_amount);
    }

    function _increaseReservedAmount(
        address _token,
        bool _isLong,
        uint256 _amount
    ) private {
        reservedAmounts[_token][_isLong] += _amount;
        totalReservedAmount += _amount;
        _validate(totalReservedAmount <= poolAmount, 43);
        emit IncreaseReservedAmount(_token, _isLong, _amount);
    }

    function _decreaseReservedAmount(
        address _token,
        bool _isLong,
        uint256 _amount
    ) private {
        require(
            reservedAmounts[_token][_isLong] >= _amount,
            "Vault: insufficient reserve"
        );
        totalReservedAmount -= _amount;
        reservedAmounts[_token][_isLong] -= _amount;
        emit DecreaseReservedAmount(_token, _isLong, _amount);
    }

    function _increaseGlobalLongSize(address _token, uint256 _amount) internal {
        globalLongSizes[_token] += _amount;

        uint256 maxSize = maxGlobalLongSizes[_token];
        if (maxSize != 0) {
            require(
                globalLongSizes[_token] <= maxSize,
                "Vault: max longs exceeded"
            );
        }
    }

    function _decreaseGlobalLongSize(address _token, uint256 _amount) private {
        uint256 size = globalLongSizes[_token];
        if (_amount > size) {
            globalLongSizes[_token] = 0;
            return;
        }

        globalLongSizes[_token] = size - _amount;
    }

    function _increaseGlobalShortSize(
        address _token,
        uint256 _amount
    ) internal {
        globalShortSizes[_token] += _amount;

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(
                globalShortSizes[_token] <= maxSize,
                "Vault: max shorts exceeded"
            );
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] = size - _amount;
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, 44);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGovAdmin() private view {
        _validate(msg.sender == ITimelockTemp(gov).admin(), 44);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateAddr(address addr) private pure {
        require(addr != address(0), "Vault: zero addr");
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], 45);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) {
            return;
        }
        _validate(tx.gasprice <= maxGasPrice, 46);
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }

    function resetPermanentFee(address to) external {
        _onlyGovAdmin();

        require(permanentPoolAmount != 0, "Vault: nothing to reset");
        uint _permanentPoolAmount = permanentPoolAmount;
        _decreasePoolAmount(_permanentPoolAmount);
        permanentPoolAmount = 0;
        _transferOut(_permanentPoolAmount, to);
    }
}
