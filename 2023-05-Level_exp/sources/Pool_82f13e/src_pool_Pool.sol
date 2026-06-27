// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.15;

import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "openzeppelin/interfaces/IERC20Metadata.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {SignedIntOps} from "../lib/SignedInt.sol";
import {MathUtils} from "../lib/MathUtils.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {ILevelOracle} from "../interfaces/ILevelOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {IPool, Side, TokenWeight} from "../interfaces/IPool.sol";
import {
    PoolStorage,
    Position,
    PoolTokenInfo,
    Fee,
    AssetInfo,
    PRECISION,
    LP_INITIAL_PRICE,
    MAX_BASE_SWAP_FEE,
    MAX_TAX_BASIS_POINT,
    MAX_POSITION_FEE,
    MAX_LIQUIDATION_FEE,
    MAX_INTEREST_RATE,
    MAX_ASSETS,
    MAX_MAINTENANCE_MARGIN
} from "./PoolStorage.sol";
import {PoolErrors} from "./PoolErrors.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {SafeCast} from "../lib/SafeCast.sol";

uint256 constant USD_VALUE_DECIMAL = 30;
uint256 constant MIN_SWAP_FEE = 10000000; // 0.1%

struct IncreasePositionVars {
    uint256 reserveAdded;
    uint256 collateralAmount;
    uint256 collateralValueAdded;
    uint256 feeValue;
    uint256 daoFee;
    uint256 indexPrice;
    uint256 sizeChanged;
    uint256 feeAmount;
    uint256 totalLpFee;
}

/// @notice common variable used accross decrease process
struct DecreasePositionVars {
    /// @notice santinized input: collateral value able to be withdraw
    uint256 collateralReduced;
    /// @notice santinized input: position size to decrease, capped to position's size
    uint256 sizeChanged;
    /// @notice current price of index
    uint256 indexPrice;
    /// @notice current price of collateral
    uint256 collateralPrice;
    /// @notice postion's remaining collateral value in USD after decrease position
    uint256 remainingCollateral;
    /// @notice reserve reduced due to reducion process
    uint256 reserveReduced;
    /// @notice total value of fee to be collect (include dao fee and LP fee)
    uint256 feeValue;
    /// @notice amount of collateral taken as fee
    uint256 daoFee;
    /// @notice real transfer out amount to user
    uint256 payout;
    /// @notice 'net' PnL (fee not counted)
    int256 pnl;
    int256 poolAmountReduced;
    uint256 totalLpFee;
}

/// @dev the only sender can add liquidity to closed tranche
address constant WHITELISTED_LIQUIDITY_PROVIDER = 0x6442b001c5AcCE8cb71986ad65B22684821A927A;
/// @dev the choosen tranche which remain
address constant TARGET_TRANCHE = 0xB5C42F84Ab3f786bCA9761240546AA9cEC1f8821;

contract Pool is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PoolStorage, IPool {
    using SignedIntOps for int256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /* =========== MODIFIERS ========== */
    modifier onlyOrderManager() {
        _requireOrderManager();
        _;
    }

    modifier onlyAsset(address _token) {
        _validateAsset(_token);
        _;
    }

    modifier onlyListedToken(address _token) {
        _requireListedToken(_token);
        _;
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /* ======== INITIALIZERS ========= */
    // function initialize(
    //     uint256 _maxLeverage,
    //     uint256 _positionFee,
    //     uint256 _liquidationFee,
    //     uint256 _interestRate,
    //     uint256 _accrualInterval,
    //     uint256 _maintainanceMargin
    // ) external initializer {
    //     __Ownable_init();
    //     __ReentrancyGuard_init();
    //     _setMaxLeverage(_maxLeverage);
    //     _setPositionFee(_positionFee, _liquidationFee);
    //     _setInterestRate(_interestRate, _accrualInterval);
    //     _setMaintenanceMargin(_maintainanceMargin);
    //     fee.daoFee = PRECISION;
    // }

    // ========= View functions =========

    function validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        external
        view
        returns (bool)
    {
        return _validateToken(_indexToken, _collateralToken, _side, _isIncrease);
    }

    function getPoolAsset(address _token) external view returns (AssetInfo memory) {
        return _getPoolAsset(_token);
    }

    function getAllTranchesLength() external view returns (uint256) {
        return allTranches.length;
    }

    function getPoolValue(bool _max) external view returns (uint256) {
        return _getPoolValue(_max);
    }

    function getTrancheValue(address _tranche, bool _max) external view returns (uint256 sum) {
        return _getTrancheValue(_tranche, _max);
    }

    function calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        return _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
    }

    function calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        external
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 feeAmount)
    {
        (outAmount, outAmountAfterFee, feeAmount,) = _calcRemoveLiquidity(_tranche, _tokenOut, _lpAmount);
    }

    // ============= Mutative functions =============

    function addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        nonReentrant
        onlyListedToken(_token)
    {
        _checkSwapAllowed();
        _validateTranche(_tranche);
        _accrueInterest(_token);
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amountIn);
        _amountIn = _requireAmount(_getAmountIn(_token));

        (uint256 amountInAfterDaoFee, uint256 daoFee, uint256 lpAmount) = calcAddLiquidity(_tranche, _token, _amountIn);
        if (lpAmount < _minLpAmount) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_token].feeReserve += daoFee;
        trancheAssets[_tranche][_token].poolAmount += amountInAfterDaoFee;
        _validateMaxLiquidity(_token);
        refreshVirtualPoolValue();

        ILPToken(_tranche).mint(_to, lpAmount);
        emit LiquidityAdded(_tranche, msg.sender, _token, _amountIn, lpAmount, daoFee);
    }

    function removeLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
        nonReentrant
        onlyAsset(_tokenOut)
    {
        _checkSwapAllowed();
        _validateTranche(_tranche);
        _accrueInterest(_tokenOut);
        _requireAmount(_lpAmount);
        ILPToken lpToken = ILPToken(_tranche);

        (, uint256 outAmountAfterFee, uint256 daoFee,) = _calcRemoveLiquidity(_tranche, _tokenOut, _lpAmount);
        if (outAmountAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_tokenOut].feeReserve += daoFee;
        _decreaseTranchePoolAmount(_tranche, _tokenOut, outAmountAfterFee + daoFee);
        refreshVirtualPoolValue();

        lpToken.burnFrom(msg.sender, _lpAmount);
        _doTransferOut(_tokenOut, _to, outAmountAfterFee);

        emit LiquidityRemoved(_tranche, msg.sender, _tokenOut, _lpAmount, outAmountAfterFee, daoFee);
    }

    function migrateLP(address _fromTranche, uint256 _lpAmount, address _viaToken, uint256 _minOut, address _to)
        external
        nonReentrant
    {
        _validateTranche(_fromTranche);
        _accrueInterest(_viaToken);
        _requireAmount(_lpAmount);

        uint256 viaTokenPrice = _getPrice(_viaToken, true);
        uint256 fromTrancheValue = _getTrancheValue(_fromTranche, true);
        uint256 targetTrancheValue = _getTrancheValue(TARGET_TRANCHE, true);

        uint256 valueChange = (_lpAmount * fromTrancheValue) / ILPToken(_fromTranche).totalSupply();
        uint256 viaTokenOut = valueChange / viaTokenPrice;
        // skip zero check
        uint256 targetLpOut = valueChange * ILPToken(TARGET_TRANCHE).totalSupply() / targetTrancheValue;

        if (targetLpOut < _minOut) revert PoolErrors.SlippageExceeded();

        _decreaseTranchePoolAmount(_fromTranche, _viaToken, viaTokenOut);
        trancheAssets[TARGET_TRANCHE][_viaToken].poolAmount += viaTokenOut;

        ILPToken(_fromTranche).burnFrom(msg.sender, _lpAmount);
        ILPToken(TARGET_TRANCHE).mint(_to, targetLpOut);

        emit LiquidityRemoved(_fromTranche, msg.sender, _viaToken, _lpAmount, viaTokenOut, 0);
        emit LiquidityAdded(TARGET_TRANCHE, msg.sender, _viaToken, viaTokenOut, targetLpOut, 0);
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _minOut, address _to, bytes calldata extradata)
        external
        nonReentrant
        onlyListedToken(_tokenIn)
        onlyAsset(_tokenOut)
    {
        _checkSwapAllowed();
        if (_tokenIn == _tokenOut) {
            revert PoolErrors.SameTokenSwap(_tokenIn);
        }
        _accrueInterest(_tokenIn);
        _accrueInterest(_tokenOut);
        uint256 amountIn = _requireAmount(_getAmountIn(_tokenIn));
        (uint256 amountOutAfterFee, uint256 swapFee) = _calcSwapOutput(_tokenIn, _tokenOut, amountIn);
        if (amountOutAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }
        {
            (uint256 daoFee, uint256 lpFee) = _calcDaoFee(swapFee);
            poolTokens[_tokenIn].feeReserve += daoFee;
            _rebalanceTranches(_tokenIn, amountIn - swapFee, _tokenOut, amountOutAfterFee, lpFee);
        }
        _validateMaxLiquidity(_tokenIn);
        _doTransferOut(_tokenOut, _to, amountOutAfterFee);
        emit Swap(msg.sender, _tokenIn, _tokenOut, amountIn, amountOutAfterFee, swapFee);
        if (address(poolHook) != address(0)) {
            poolHook.postSwap(_to, _tokenIn, _tokenOut, abi.encode(amountIn, amountOutAfterFee, swapFee, extradata));
        }
    }

    function increasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _sizeChanged,
        Side _side
    ) external onlyOrderManager {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, true);
        IncreasePositionVars memory vars;
        vars.collateralAmount = _requireAmount(_getAmountIn(_collateralToken));
        uint256 collateralPrice = _getCollateralPrice(_collateralToken, true);
        vars.collateralValueAdded = collateralPrice * vars.collateralAmount;
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];

        if (position.size == 0) {
            positionOpenTimestamp[key] = block.timestamp;
        } else if (positionOpenTimestamp[key] == 0) {
            // disable increase old position due to trache collapsing
            revert("Increase position disabled");
        }

        vars.indexPrice = _getIndexPrice(_indexToken, _side, true);
        vars.sizeChanged = _sizeChanged;

        // update position
        vars.feeValue = _calcPositionFee(position, vars.sizeChanged, borrowIndex);
        vars.feeValue = feeDiscount.tryDiscount(_owner, _calcPositionFee(position, vars.sizeChanged, borrowIndex));
        vars.feeAmount = vars.feeValue / collateralPrice;
        (vars.daoFee, vars.totalLpFee) = _calcDaoFee(vars.feeAmount);
        vars.reserveAdded = vars.sizeChanged / collateralPrice;

        position.entryPrice = PositionUtils.calcAveragePrice(
            _side, position.size, position.size + vars.sizeChanged, position.entryPrice, vars.indexPrice, 0
        );
        position.collateralValue =
            MathUtils.zeroCapSub(position.collateralValue + vars.collateralValueAdded, vars.feeValue);
        position.size = position.size + vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount += vars.reserveAdded;

        if (vars.sizeChanged != 0 && (position.size > position.collateralValue * maxLeverage)) {
            revert PoolErrors.InvalidLeverage(position.size, position.collateralValue, maxLeverage);
        }

        _validatePosition(position, _collateralToken, _side, vars.indexPrice);

        // update pool assets
        _reservePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        positions[key] = position;

        emit IncreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralAmount,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.feeValue
        );

        emit UpdatePosition(
            key,
            position.size,
            position.collateralValue,
            position.entryPrice,
            position.borrowIndex,
            position.reserveAmount,
            vars.indexPrice
        );

        if (address(poolHook) != address(0)) {
            poolHook.postIncreasePosition(
                _owner,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(_sizeChanged, vars.collateralValueAdded, vars.feeValue)
            );
        }
    }

    function decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external onlyOrderManager {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];

        if (position.size == 0) {
            revert PoolErrors.PositionNotExists(_owner, _indexToken, _collateralToken, _side);
        }

        DecreasePositionVars memory vars = _calcDecreasePayout(
            position, _owner, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged, false
        );

        // reset to actual reduced value instead of user input
        vars.collateralReduced = position.collateralValue - vars.remainingCollateral;
        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        position.size = position.size - vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        position.collateralValue = vars.remainingCollateral;

        _validatePosition(position, _collateralToken, _side, vars.indexPrice);

        emit DecreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralReduced,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.pnl.asTuple(),
            vars.feeValue
        );
        if (position.size == 0) {
            emit ClosePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount
            );
            // delete position when closed
            delete positions[key];
        } else {
            emit UpdatePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount,
                vars.indexPrice
            );
            positions[key] = position;
        }
        _doTransferOut(_collateralToken, _receiver, vars.payout);

        if (address(poolHook) != address(0)) {
            poolHook.postDecreasePosition(
                _owner,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(vars.sizeChanged, vars.collateralReduced, vars.feeValue)
            );
        }
    }

    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side) external {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);

        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 markPrice = oracle.getReferencePrice(_indexToken);
        if (!_liquidatePositionAllowed(position, _side, markPrice, borrowIndex)) {
            revert PoolErrors.PositionNotLiquidated(key);
        }

        DecreasePositionVars memory vars = _calcDecreasePayout(
            position, _account, _indexToken, _collateralToken, _side, position.size, position.collateralValue, true
        );

        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);

        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _side,
            position.size,
            position.collateralValue - vars.remainingCollateral,
            position.reserveAmount,
            vars.indexPrice,
            vars.pnl.asTuple(),
            vars.feeValue
        );

        delete positions[key];
        _doTransferOut(_collateralToken, _account, vars.payout);
        _doTransferOut(_collateralToken, msg.sender, fee.liquidationFee / vars.collateralPrice);

        if (address(poolHook) != address(0)) {
            poolHook.postLiquidatePosition(
                _account,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(position.size, position.collateralValue, vars.feeValue)
            );
        }
    }

    function refreshVirtualPoolValue() public {
        virtualPoolValue = (_getPoolValue(true) + _getPoolValue(false)) / 2;
    }

    // ========= ADMIN FUNCTIONS ========

    function setMaxLiquidity(address _asset, uint256 _value) external onlyController onlyAsset(_asset) {
        maxLiquidity[_asset] = _value;
        emit MaxLiquiditySet(_asset, _value);
    }

    function withdrawFee(address _token, address _recipient) external onlyAsset(_token) {
        if (msg.sender != feeDistributor) {
            revert PoolErrors.FeeDistributorOnly();
        }
        uint256 amount = poolTokens[_token].feeReserve;
        poolTokens[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
        emit DaoFeeWithdrawn(_token, _recipient, amount);
    }

    function setTargetWeight(TokenWeight[] memory tokens) external onlyController {
        uint256 nTokens = tokens.length;
        if (nTokens != allAssets.length) {
            revert PoolErrors.RequireAllTokens();
        }
        uint256 total;
        for (uint256 i = 0; i < nTokens; ++i) {
            TokenWeight memory item = tokens[i];
            assert(isAsset[item.token]);
            // unlisted token always has zero weight
            uint256 weight = isListed[item.token] ? item.weight : 0;
            targetWeights[item.token] = weight;
            total += weight;
        }
        totalWeight = total;
        emit TokenWeightSet(tokens);
    }

    function setMaxGlobalPositionSize(address _token, uint256 _maxGlobalLongRatio, uint256 _maxGlobalShortSize)
        external
        onlyController
        onlyAsset(_token)
    {
        if (isStableCoin[_token]) {
            revert PoolErrors.NotApplicableForStableCoin();
        }

        _validateMaxValue(_maxGlobalLongRatio, PRECISION);
        maxGlobalLongSizeRatios[_token] = _maxGlobalLongRatio;
        maxGlobalShortSizes[_token] = _maxGlobalShortSize;
        emit MaxGlobalPositionSizeSet(_token, _maxGlobalLongRatio, _maxGlobalShortSize);
    }

    /// @notice move assets between tranches without breaking constrants. Called by controller in rebalance process
    /// to mitigate tranche LP exposure
    function rebalanceAsset(
        address _fromTranche,
        address _fromToken,
        uint256 _fromAmount,
        address _toTranche,
        address _toToken
    ) external onlyController {
        uint256 toAmount = MathUtils.frac(_fromAmount, _getPrice(_fromToken, true), _getPrice(_toToken, true));
        _decreaseTranchePoolAmount(_fromTranche, _fromToken, _fromAmount);
        _decreaseTranchePoolAmount(_toTranche, _toToken, toAmount);
        trancheAssets[_fromTranche][_toToken].poolAmount += toAmount;
        trancheAssets[_toTranche][_fromToken].poolAmount += _fromAmount;
        emit AssetRebalanced();
    }

    function setSwapAllowed(address _sender, bool _allowed) external virtual onlyOwner {
        if (_allowed != allowSwap[_sender]) {
            allowSwap[_sender] = _allowed;
            emit SwapAllowanceChanged(_sender, _allowed);
        }
    }

    // ======== internal functions =========
    function _setMaxLeverage(uint256 _maxLeverage) internal {
        if (_maxLeverage == 0) {
            revert PoolErrors.InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        emit MaxLeverageChanged(_maxLeverage);
    }

    function _setMaintenanceMargin(uint256 _ratio) internal {
        _validateMaxValue(_ratio, MAX_MAINTENANCE_MARGIN);
        maintenanceMargin = _ratio;
        emit MaintenanceMarginChanged(_ratio);
    }

    function _setInterestRate(uint256 _interestRate, uint256 _accrualInterval) internal {
        if (_accrualInterval == 0) {
            revert PoolErrors.InvalidInterval();
        }
        _validateMaxValue(_interestRate, MAX_INTEREST_RATE);
        interestRate = _interestRate;
        accrualInterval = _accrualInterval;
        emit InterestRateSet(_interestRate, _accrualInterval);
    }

    function _validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
        returns (bool)
    {
        if (!isAsset[_indexToken] || !isAsset[_collateralToken] || isStableCoin[_indexToken]) {
            return false;
        }

        if (_isIncrease && (!isListed[_indexToken] || !isListed[_collateralToken])) {
            return false;
        }

        return _side == Side.LONG ? _indexToken == _collateralToken : isStableCoin[_collateralToken];
    }

    function calcAddLiquidity(address _tranche, address _token, uint256 _amountIn)
        public
        view
        returns (uint256 amountInAfterDaoFee, uint256 daoFee, uint256 lpAmount)
    {
        if (
            (_tranche != TARGET_TRANCHE && msg.sender != WHITELISTED_LIQUIDITY_PROVIDER)
                || (!isStableCoin[_token] && riskFactor[_token][_tranche] == 0)
        ) {
            revert PoolErrors.AddLiquidityNotAllowed(_tranche, _token);
        }
        uint256 tokenPrice = _getPrice(_token, false);
        uint256 valueChange = _amountIn * tokenPrice;

        uint256 _fee = _calcFeeRate(_token, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, true);
        uint256 userAmount = MathUtils.frac(_amountIn, PRECISION - _fee, PRECISION);
        (daoFee,) = _calcDaoFee(_amountIn - userAmount);
        amountInAfterDaoFee = _amountIn - daoFee;

        uint256 trancheValue = _getTrancheValue(_tranche, true);
        uint256 lpSupply = ILPToken(_tranche).totalSupply();
        if (lpSupply == 0 || trancheValue == 0) {
            lpAmount = MathUtils.frac(userAmount, tokenPrice, LP_INITIAL_PRICE);
        } else {
            lpAmount = userAmount * tokenPrice * lpSupply / trancheValue;
        }
    }

    function _calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        internal
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 daoFee, uint256 tokenPrice)
    {
        tokenPrice = _getPrice(_tokenOut, true);
        uint256 trancheValue = _getTrancheValue(_tranche, false);
        uint256 valueChange = (_lpAmount * trancheValue) / ILPToken(_tranche).totalSupply();
        uint256 _fee = _calcFeeRate(_tokenOut, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, false);
        outAmount = valueChange / tokenPrice;
        outAmountAfterFee = MathUtils.frac(outAmount, PRECISION - _fee, PRECISION);
        (daoFee,) = _calcDaoFee(outAmount - outAmountAfterFee);
    }

    function _calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        internal
        view
        returns (uint256 amountOutAfterFee, uint256 feeAmount)
    {
        uint256 priceIn = _getPrice(_tokenIn, false);
        uint256 priceOut = _getPrice(_tokenOut, true);
        uint256 valueChange = _amountIn * priceIn;
        bool isStableSwap = isStableCoin[_tokenIn] && isStableCoin[_tokenOut];
        uint256 feeIn = _calcSwapFee(isStableSwap, _tokenIn, priceIn, valueChange, true);
        uint256 feeOut = _calcSwapFee(isStableSwap, _tokenOut, priceOut, valueChange, false);
        uint256 _fee = feeIn > feeOut ? feeIn : feeOut;

        amountOutAfterFee = valueChange * (PRECISION - _fee) / priceOut / PRECISION;
        feeAmount = (valueChange * _fee) / priceIn / PRECISION;
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    function _validatePosition(Position memory _position, address _collateralToken, Side _side, uint256 _indexPrice)
        internal
        view
    {
        if (_position.size != 0 && _position.collateralValue == 0) {
            revert PoolErrors.InvalidPositionSize();
        }

        if (_position.size < _position.collateralValue) {
            revert PoolErrors.InvalidLeverage(_position.size, _position.collateralValue, maxLeverage);
        }

        uint256 borrowIndex = poolTokens[_collateralToken].borrowIndex;
        if (_liquidatePositionAllowed(_position, _side, _indexPrice, borrowIndex)) {
            revert PoolErrors.UpdateCauseLiquidation();
        }
    }

    function _requireValidTokenPair(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
    {
        if (!_validateToken(_indexToken, _collateralToken, _side, _isIncrease)) {
            revert PoolErrors.InvalidTokenPair(_indexToken, _collateralToken);
        }
    }

    function _validateAsset(address _token) internal view {
        if (!isAsset[_token]) {
            revert PoolErrors.UnknownToken(_token);
        }
    }

    function _validateTranche(address _tranche) internal view {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
    }

    function _requireAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
    }

    function _onlyController() internal view {
        require(msg.sender == controller || msg.sender == owner(), "onlyController");
    }

    function _requireAmount(uint256 _amount) internal pure returns (uint256) {
        if (_amount == 0) {
            revert PoolErrors.ZeroAmount();
        }

        return _amount;
    }

    function _requireListedToken(address _token) internal view {
        if (!isListed[_token]) {
            revert PoolErrors.AssetNotListed(_token);
        }
    }

    function _requireOrderManager() internal view {
        if (msg.sender != orderManager) {
            revert PoolErrors.OrderManagerOnly();
        }
    }

    function _validateMaxValue(uint256 _input, uint256 _max) internal pure {
        if (_input > _max) {
            revert PoolErrors.ValueTooHigh(_max);
        }
    }

    function _getAmountIn(address _token) internal returns (uint256 amount) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        amount = balance - poolTokens[_token].poolBalance;
        poolTokens[_token].poolBalance = balance;
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount != 0) {
            IERC20 token = IERC20(_token);
            token.safeTransfer(_to, _amount);
            poolTokens[_token].poolBalance = token.balanceOf(address(this));
        }
    }

    function _accrueInterest(address _token) internal returns (uint256) {
        PoolTokenInfo memory tokenInfo = poolTokens[_token];
        AssetInfo memory asset = _getPoolAsset(_token);
        uint256 _now = block.timestamp;
        if (tokenInfo.lastAccrualTimestamp == 0 || asset.poolAmount == 0) {
            tokenInfo.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
        } else {
            uint256 nInterval = (_now - tokenInfo.lastAccrualTimestamp) / accrualInterval;
            if (nInterval == 0) {
                return tokenInfo.borrowIndex;
            }

            tokenInfo.borrowIndex += (nInterval * interestRate * asset.reservedAmount) / asset.poolAmount;
            tokenInfo.lastAccrualTimestamp += nInterval * accrualInterval;
        }

        poolTokens[_token] = tokenInfo;
        emit InterestAccrued(_token, tokenInfo.borrowIndex);
        return tokenInfo.borrowIndex;
    }

    /// @notice calculate adjusted fee rate
    /// fee is increased or decreased based on action's effect to pool amount
    /// each token has their target weight set by gov
    /// if action make the weight of token far from its target, fee will be increase, vice versa
    function _calcSwapFee(bool _isStableSwap, address _token, uint256 _tokenPrice, uint256 _valueChange, bool _isSwapIn)
        internal
        view
        returns (uint256)
    {
        (uint256 baseSwapFee, uint256 taxBasisPoint) = _isStableSwap
            ? (fee.stableCoinBaseSwapFee, fee.stableCoinTaxBasisPoint)
            : (fee.baseSwapFee, fee.taxBasisPoint);
        return _calcFeeRate(_token, _tokenPrice, _valueChange, baseSwapFee, taxBasisPoint, _isSwapIn);
    }

    function _calcFeeRate(
        address _token,
        uint256 _tokenPrice,
        uint256 _valueChange,
        uint256 _baseFee,
        uint256 _taxBasisPoint,
        bool _isIncrease
    ) internal view returns (uint256) {
        uint256 _targetValue = totalWeight == 0 ? 0 : (targetWeights[_token] * virtualPoolValue) / totalWeight;
        if (_targetValue == 0) {
            return _baseFee;
        }
        uint256 _currentValue = _tokenPrice * _getPoolAsset(_token).poolAmount;
        uint256 _nextValue = _isIncrease ? _currentValue + _valueChange : _currentValue - _valueChange;
        uint256 initDiff = MathUtils.diff(_currentValue, _targetValue);
        uint256 nextDiff = MathUtils.diff(_nextValue, _targetValue);
        if (nextDiff < initDiff) {
            uint256 feeAdjust = (_taxBasisPoint * initDiff) / _targetValue;
            uint256 rate = MathUtils.zeroCapSub(_baseFee, feeAdjust);
            return rate > MIN_SWAP_FEE ? rate : MIN_SWAP_FEE;
        } else {
            uint256 avgDiff = (initDiff + nextDiff) / 2;
            uint256 feeAdjust = avgDiff > _targetValue ? _taxBasisPoint : (_taxBasisPoint * avgDiff) / _targetValue;
            return _baseFee + feeAdjust;
        }
    }

    function _getPoolValue(bool _max) internal view returns (uint256 sum) {
        uint256[] memory prices = _getAllPrices(_max);
        for (uint256 i = 0; i < allTranches.length;) {
            sum += _getTrancheValue(allTranches[i], prices);
            unchecked {
                ++i;
            }
        }
    }

    function _getAllPrices(bool _max) internal view returns (uint256[] memory) {
        return oracle.getMultiplePrices(allAssets, _max);
    }

    function _getTrancheValue(address _tranche, bool _max) internal view returns (uint256 sum) {
        return _getTrancheValue(_tranche, _getAllPrices(_max));
    }

    function _getTrancheValue(address _tranche, uint256[] memory prices) internal view returns (uint256 sum) {
        int256 aum;

        for (uint256 i = 0; i < allAssets.length;) {
            address token = allAssets[i];
            assert(isAsset[token]); // double check
            AssetInfo memory asset = trancheAssets[_tranche][token];
            uint256 price = prices[i];
            if (isStableCoin[token]) {
                aum = aum + (price * asset.poolAmount).toInt256();
            } else {
                uint256 averageShortPrice = averageShortPrices[_tranche][token];
                int256 shortPnl = PositionUtils.calcPnl(Side.SHORT, asset.totalShortSize, averageShortPrice, price);
                aum = aum + ((asset.poolAmount - asset.reservedAmount) * price + asset.guaranteedValue).toInt256()
                    - shortPnl;
            }
            unchecked {
                ++i;
            }
        }

        // aum MUST not be negative. If it is, please debug
        return aum.toUint256();
    }

    function _decreaseTranchePoolAmount(address _tranche, address _token, uint256 _amount) internal {
        AssetInfo memory asset = trancheAssets[_tranche][_token];
        asset.poolAmount -= _amount;
        if (asset.poolAmount < asset.reservedAmount) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
        trancheAssets[_tranche][_token] = asset;
    }

    /// @notice return pseudo pool asset by sum all tranches asset
    function _getPoolAsset(address _token) internal view returns (AssetInfo memory asset) {
        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            asset.poolAmount += trancheAssets[tranche][_token].poolAmount;
            asset.reservedAmount += trancheAssets[tranche][_token].reservedAmount;
            asset.totalShortSize += trancheAssets[tranche][_token].totalShortSize;
            asset.guaranteedValue += trancheAssets[tranche][_token].guaranteedValue;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice reserve asset when open position
    function _reservePoolAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);

        uint256 maxReserve = collateral.poolAmount;

        if (_vars.sizeChanged > 0) {
            if (_side == Side.LONG) {
                uint256 maxReserveRatio = maxGlobalLongSizeRatios[_indexToken];
                if (maxReserveRatio != 0) {
                    maxReserve = MathUtils.frac(maxReserve, maxReserveRatio, PRECISION);
                }
            } else {
                uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
                uint256 globalShortSize = collateral.totalShortSize + _vars.sizeChanged;
                if (maxGlobalShortSize != 0 && maxGlobalShortSize < globalShortSize) {
                    revert PoolErrors.MaxGlobalShortSizeExceeded(_indexToken, globalShortSize);
                }
            }
        }

        if (collateral.reservedAmount + _vars.reserveAdded > maxReserve) {
            revert PoolErrors.InsufficientPoolAmount(_collateralToken);
        }

        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        _reserveTranchesAsset(_key, _vars, _indexToken, _collateralToken, _side);
    }

    /// @notice release asset and take or distribute realized PnL when close position
    function _releasePoolAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);

        if (collateral.reservedAmount < _vars.reserveReduced) {
            revert PoolErrors.ReserveReduceTooMuch(_collateralToken);
        }

        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        _releaseTranchesAsset(_key, _vars, _indexToken, _collateralToken, _side);
    }

    function _reserveTranchesAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        uint256[] memory shares;
        uint256 totalShare;
        if (_vars.reserveAdded != 0) {
            totalShare = _vars.reserveAdded;
            shares = _calcTrancheSharesAmount(_indexToken, _collateralToken, totalShare, false);
        } else {
            totalShare = _vars.collateralAmount;
            shares = _calcTrancheSharesAmount(_indexToken, _collateralToken, totalShare, true);
        }

        for (uint256 i = 0; i < shares.length;) {
            address tranche = allTranches[i];
            uint256 share = shares[i];
            AssetInfo memory collateral = trancheAssets[tranche][_collateralToken];

            uint256 reserveAmount = MathUtils.frac(_vars.reserveAdded, share, totalShare);
            tranchePositionReserves[tranche][_key] += reserveAmount;
            collateral.reservedAmount += reserveAmount;
            collateral.poolAmount +=
                MathUtils.frac(_vars.totalLpFee, riskFactor[_indexToken][tranche], totalRiskFactor[_indexToken]);

            if (_side == Side.LONG) {
                collateral.poolAmount = MathUtils.addThenSubWithFraction(
                    collateral.poolAmount, _vars.collateralAmount, _vars.feeAmount, share, totalShare
                );
                // ajust guaranteed
                // guaranteed value = total(size - (collateral - fee))
                // delta_guaranteed value = sizechange + fee - collateral
                collateral.guaranteedValue = MathUtils.addThenSubWithFraction(
                    collateral.guaranteedValue,
                    _vars.sizeChanged + _vars.feeValue,
                    _vars.collateralValueAdded,
                    share,
                    totalShare
                );
            } else {
                uint256 sizeChanged = MathUtils.frac(_vars.sizeChanged, share, totalShare);
                uint256 indexPrice = _vars.indexPrice;
                _updateGlobalShortPosition(tranche, _indexToken, sizeChanged, true, indexPrice, 0);
            }

            trancheAssets[tranche][_collateralToken] = collateral;
            unchecked {
                ++i;
            }
        }
    }

    function _releaseTranchesAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        uint256 totalShare = positions[_key].reserveAmount;

        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            uint256 share = tranchePositionReserves[tranche][_key];
            AssetInfo memory collateral = trancheAssets[tranche][_collateralToken];

            {
                uint256 reserveReduced = MathUtils.frac(_vars.reserveReduced, share, totalShare);
                tranchePositionReserves[tranche][_key] -= reserveReduced;
                collateral.reservedAmount -= reserveReduced;
            }

            uint256 lpFee =
                MathUtils.frac(_vars.totalLpFee, riskFactor[_indexToken][tranche], totalRiskFactor[_indexToken]);
            collateral.poolAmount = (
                (collateral.poolAmount + lpFee).toInt256() - _vars.poolAmountReduced.frac(share, totalShare)
            ).toUint256();

            if (collateral.poolAmount < collateral.reservedAmount) {
                revert PoolErrors.InsufficientPoolAmount(_collateralToken);
            }

            int256 pnl = _vars.pnl.frac(share, totalShare);
            if (_side == Side.LONG) {
                collateral.guaranteedValue = MathUtils.addThenSubWithFraction(
                    collateral.guaranteedValue, _vars.collateralReduced, _vars.sizeChanged, share, totalShare
                );
            } else {
                uint256 sizeChanged = MathUtils.frac(_vars.sizeChanged, share, totalShare);
                uint256 indexPrice = _vars.indexPrice;
                _updateGlobalShortPosition(tranche, _indexToken, sizeChanged, false, indexPrice, pnl);
            }
            trancheAssets[tranche][_collateralToken] = collateral;
            emit PnLDistributed(_collateralToken, tranche, pnl.abs(), pnl >= 0);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice distributed amount of token to all tranches
    /// @param _indexToken the token of which risk factors is used to calculate ratio
    /// @param _collateralToken pool amount or reserve of this token will be changed. So we must cap the amount to be changed to the
    /// max available value of this token (pool amount - reserve) when _isIncreasePoolAmount set to false
    /// @param _isIncreasePoolAmount set to true when "increase pool amount" or "decrease reserve amount"
    function _calcTrancheSharesAmount(
        address _indexToken,
        address _collateralToken,
        uint256 _amount,
        bool _isIncreasePoolAmount
    ) internal view returns (uint256[] memory reserves) {
        uint256 nTranches = allTranches.length;
        reserves = new uint256[](nTranches);
        uint256[] memory factors = new uint256[](nTranches);
        uint256[] memory maxShare = new uint256[](nTranches);

        for (uint256 i = 0; i < nTranches;) {
            address tranche = allTranches[i];
            AssetInfo memory asset = trancheAssets[tranche][_collateralToken];
            factors[i] = isStableCoin[_indexToken] ? 1 : riskFactor[_indexToken][tranche];
            maxShare[i] = _isIncreasePoolAmount ? type(uint256).max : asset.poolAmount - asset.reservedAmount;
            unchecked {
                ++i;
            }
        }

        uint256 totalFactor = isStableCoin[_indexToken] ? nTranches : totalRiskFactor[_indexToken];

        for (uint256 k = 0; k < nTranches;) {
            unchecked {
                ++k;
            }
            uint256 totalRiskFactor_ = totalFactor;
            for (uint256 i = 0; i < nTranches;) {
                uint256 riskFactor_ = factors[i];
                if (riskFactor_ != 0) {
                    uint256 shareAmount = MathUtils.frac(_amount, riskFactor_, totalRiskFactor_);
                    uint256 availableAmount = maxShare[i] - reserves[i];
                    if (shareAmount >= availableAmount) {
                        // skip this tranche on next rounds since it's full
                        shareAmount = availableAmount;
                        totalFactor -= riskFactor_;
                        factors[i] = 0;
                    }

                    reserves[i] += shareAmount;
                    _amount -= shareAmount;
                    totalRiskFactor_ -= riskFactor_;
                    if (_amount == 0) {
                        return reserves;
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }

        revert PoolErrors.CannotDistributeToTranches(_indexToken, _collateralToken, _amount, _isIncreasePoolAmount);
    }

    /// @notice rebalance fund between tranches after swap token
    function _rebalanceTranches(
        address _tokenIn,
        uint256 _amountInAfterFee,
        address _tokenOut,
        uint256 _amountOut,
        uint256 _lpFee
    ) internal {
        // amount devided to each tranche
        uint256[] memory outAmounts;
        uint256[] memory lpFeeAmounts;
        address indexToken = isStableCoin[_tokenIn] && !isStableCoin[_tokenOut] ? _tokenOut : _tokenIn;
        outAmounts = _calcTrancheSharesAmount(indexToken, _tokenOut, _amountOut, false);
        lpFeeAmounts = _calcTrancheSharesAmount(indexToken, _tokenIn, _lpFee, true);

        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            trancheAssets[tranche][_tokenOut].poolAmount -= outAmounts[i];
            trancheAssets[tranche][_tokenIn].poolAmount +=
                MathUtils.frac(_amountInAfterFee, outAmounts[i], _amountOut) + lpFeeAmounts[i];
            unchecked {
                ++i;
            }
        }
    }

    function _liquidatePositionAllowed(Position memory _position, Side _side, uint256 _indexPrice, uint256 _borrowIndex)
        internal
        view
        returns (bool allowed)
    {
        if (_position.size == 0) {
            return false;
        }
        // calculate fee needed when close position
        uint256 feeValue = _calcPositionFee(_position, _position.size, _borrowIndex);
        int256 pnl = PositionUtils.calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        int256 collateral = pnl + _position.collateralValue.toInt256();

        // liquidation occur when collateral cannot cover margin fee or lower than maintenance margin
        return collateral < 0 || uint256(collateral) * PRECISION < _position.size * maintenanceMargin
            || uint256(collateral) < (feeValue + fee.liquidationFee);
    }

    function _calcDecreasePayout(
        Position memory _position,
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _sizeChanged,
        uint256 _collateralChanged,
        bool isLiquidate
    ) internal returns (DecreasePositionVars memory vars) {
        // clean user input
        vars.sizeChanged = MathUtils.min(_position.size, _sizeChanged);
        vars.collateralReduced = _position.collateralValue < _collateralChanged || _position.size == vars.sizeChanged
            ? _position.collateralValue
            : _collateralChanged;

        vars.indexPrice = _getIndexPrice(_indexToken, _side, false);
        vars.collateralPrice = _getCollateralPrice(_collateralToken, false);

        // vars is santinized, only trust these value from now on
        vars.reserveReduced = (_position.reserveAmount * vars.sizeChanged) / _position.size;
        vars.pnl = PositionUtils.calcPnl(_side, vars.sizeChanged, _position.entryPrice, vars.indexPrice);
        vars.feeValue = _calcPositionFee(_position, vars.sizeChanged, poolTokens[_collateralToken].borrowIndex);
        if (!isLiquidate) {
            vars.feeValue = feeDiscount.tryDiscount(_owner, vars.feeValue);
        }

        // first try to deduct fee and lost (if any) from withdrawn collateral
        int256 payoutValue = vars.pnl + vars.collateralReduced.toInt256() - vars.feeValue.toInt256();
        if (isLiquidate) {
            payoutValue = payoutValue - fee.liquidationFee.toInt256();
        }
        int256 remainingCollateral = (_position.collateralValue - vars.collateralReduced).toInt256(); // subtraction never overflow, checked above
        // if the deduction is too much, try to deduct from remaining collateral
        if (payoutValue < 0) {
            remainingCollateral = remainingCollateral + payoutValue;
            payoutValue = 0;
        }
        vars.payout = uint256(payoutValue) / vars.collateralPrice;

        int256 poolValueReduced = vars.pnl;
        if (remainingCollateral < 0) {
            if (!isLiquidate) {
                revert PoolErrors.UpdateCauseLiquidation();
            }
            // if liquidate too slow, pool must take the lost
            poolValueReduced = poolValueReduced - remainingCollateral;
            vars.remainingCollateral = 0;
        } else {
            vars.remainingCollateral = uint256(remainingCollateral);
        }

        if (_side == Side.LONG) {
            poolValueReduced = poolValueReduced + vars.collateralReduced.toInt256();
        } else if (poolValueReduced < 0) {
            // in case of SHORT, trader can lost unlimited value but pool can only increase at most collateralValue - liquidationFee
            poolValueReduced = poolValueReduced.lowerCap(
                MathUtils.zeroCapSub(_position.collateralValue, vars.feeValue + fee.liquidationFee)
            );
        }
        vars.poolAmountReduced = poolValueReduced / vars.collateralPrice.toInt256();
        (vars.daoFee, vars.totalLpFee) = _calcDaoFee(vars.feeValue / vars.collateralPrice);
    }

    function _calcPositionFee(Position memory _position, uint256 _sizeChanged, uint256 _borrowIndex)
        internal
        view
        returns (uint256 feeValue)
    {
        uint256 borrowFee = ((_borrowIndex - _position.borrowIndex) * _position.size) / PRECISION;
        uint256 positionFee = (_sizeChanged * fee.positionFee) / PRECISION;
        feeValue = borrowFee + positionFee;
    }

    function _getIndexPrice(address _token, Side _side, bool _isIncrease) internal view returns (uint256) {
        // max == (_isIncrease & _side = LONG) | (!_increase & _side = SHORT)
        // max = _isIncrease == (_side == Side.LONG);
        return _getPrice(_token, _isIncrease == (_side == Side.LONG));
    }

    function _getCollateralPrice(address _token, bool _isIncrease) internal view returns (uint256) {
        return (isStableCoin[_token])
            // force collateral price = 1 incase of using stablecoin as collateral
            ? 10 ** (USD_VALUE_DECIMAL - IERC20Metadata(_token).decimals())
            : _getPrice(_token, !_isIncrease);
    }

    function _getPrice(address _token, bool _max) internal view returns (uint256) {
        return oracle.getPrice(_token, _max);
    }

    function _validateMaxLiquidity(address _token) internal view {
        uint256 max = maxLiquidity[_token];
        if (max == 0) {
            return;
        }

        uint256 poolAmount = _getPoolAsset(_token).poolAmount;
        if (max < poolAmount) {
            revert PoolErrors.MaxLiquidityReach();
        }
    }

    function _updateGlobalShortPosition(
        address _tranche,
        address _indexToken,
        uint256 _sizeChanged,
        bool _isIncrease,
        uint256 _indexPrice,
        int256 _realizedPnl
    ) internal {
        uint256 lastSize = trancheAssets[_tranche][_indexToken].totalShortSize;
        uint256 nextSize = _isIncrease ? lastSize + _sizeChanged : MathUtils.zeroCapSub(lastSize, _sizeChanged);
        uint256 entryPrice = averageShortPrices[_tranche][_indexToken];
        uint256 shortPrice =
            PositionUtils.calcAveragePrice(Side.SHORT, lastSize, nextSize, entryPrice, _indexPrice, _realizedPnl);
        averageShortPrices[_tranche][_indexToken] = shortPrice;
        trancheAssets[_tranche][_indexToken].totalShortSize = nextSize;
    }

    function _calcDaoFee(uint256 _feeAmount) internal view returns (uint256 daoFee, uint256 lpFee) {
        daoFee = MathUtils.frac(_feeAmount, fee.daoFee, PRECISION);
        lpFee = _feeAmount - daoFee;
    }

    function _checkSwapAllowed() internal view {
        if (msg.sender != orderManager && !allowSwap[msg.sender]) {
            revert PoolErrors.SwapNotAllowed();
        }
    }
}
