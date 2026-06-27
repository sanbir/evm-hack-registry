// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20Upgradeable, SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {GovernableUpgradeable} from "../access/GovernableUpgradeable.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IPlpManager.sol";
import "./interfaces/IShortsTracker.sol";
import "../tokens/interfaces/IUSDP.sol";
import "../tokens/interfaces/IMintable.sol";

contract PlpManager is
    ReentrancyGuardUpgradeable,
    GovernableUpgradeable,
    IPlpManager
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant PRICE_PRECISION = 10**30;
    uint256 public constant USDP_DECIMALS = 18;
    uint256 public constant PLP_PRECISION = 10**18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    IShortsTracker public shortsTracker;
    address public override collateralToken;
    address public override usdp;
    address public override plp;

    uint256 public override cooldownDuration;
    mapping(address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    uint256 public shortsTrackerAveragePriceWeight;
    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        uint256 amount,
        uint256 aumInUsdp,
        uint256 plpSupply,
        uint256 usdpAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        uint256 plpAmount,
        uint256 aumInUsdp,
        uint256 plpSupply,
        uint256 usdpAmount,
        uint256 amountOut
    );

    function initialize(
        address _vault,
        address _collateralToken,
        address _usdp,
        address _plp,
        address _shortsTracker,
        uint256 _cooldownDuration
    ) public initializer {
        __ReentrancyGuard_init();
        __GovernableUpgradeable_init();

        vault = IVault(_vault);
        collateralToken = _collateralToken;
        usdp = _usdp;
        plp = _plp;
        shortsTracker = IShortsTracker(_shortsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    function setShortsTracker(IShortsTracker _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    function setShortsTrackerAveragePriceWeight(
        uint256 _shortsTrackerAveragePriceWeight
    ) external override onlyGov {
        require(
            _shortsTrackerAveragePriceWeight <= BASIS_POINTS_DIVISOR,
            "PlpManager: invalid weight"
        );
        shortsTrackerAveragePriceWeight = _shortsTrackerAveragePriceWeight;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(uint256 _cooldownDuration)
        external
        override
        onlyGov
    {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "PlpManager: invalid _cooldownDuration"
        );
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction)
        external
        onlyGov
    {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    function addLiquidity(
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert("PlpManager: action not enabled");
        }
        return
            _addLiquidity(msg.sender, msg.sender, _amount, _minUsdp, _minPlp);
    }

    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return
            _addLiquidity(
                _fundingAccount,
                _account,
                _amount,
                _minUsdp,
                _minPlp
            );
    }

    function removeLiquidity(
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        if (inPrivateMode) {
            revert("PlpManager: action not enabled");
        }
        return _removeLiquidity(msg.sender, _plpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(
        address _account,
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _plpAmount, _minOut, _receiver);
    }

    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20Upgradeable(plp).totalSupply();
        return (aum * PLP_PRECISION) / supply;
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdp(bool maximise)
        public
        view
        override
        returns (uint256)
    {
        uint256 aum = getAum(maximise);
        return (aum * (10**USDP_DECIMALS)) / PRICE_PRECISION;
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
        IVault _vault = vault;

        uint256 collateralTokenPrice = maximise
            ? _vault.getMaxPrice(collateralToken)
            : _vault.getMinPrice(collateralToken);

        uint256 collateralDecimals = _vault.tokenDecimals(collateralToken);

        uint256 currentAmmDeduction = (vault.permanentPoolAmount() *
            collateralTokenPrice) / (10**collateralDecimals);
        aum +=
            (vault.poolAmount() * collateralTokenPrice) /
            (10**collateralDecimals);

        bool _maximise = maximise;

        for (uint256 i; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted || token == collateralToken) {
                continue;
            }

            uint256 maxPrice = _vault.getMaxPrice(token);
            uint256 minPrice = _vault.getMinPrice(token);

            // add global profit / loss
            uint256 shortSize = _vault.globalShortSizes(token);
            uint256 longSize = _vault.globalLongSizes(token);

            if (longSize > 0) {
                (uint256 delta, bool hasProfit) = getGlobalDelta(
                    token,
                    _maximise ? minPrice : maxPrice,
                    longSize,
                    true
                );
                if (!hasProfit) {
                    // add lossees from longs
                    aum += delta;
                } else {
                    currentAmmDeduction += delta;
                }
            }

            if (shortSize > 0) {
                (uint256 delta, bool hasProfit) = getGlobalDelta(
                    token,
                    _maximise ? maxPrice : minPrice,
                    shortSize,
                    false
                );
                if (!hasProfit) {
                    // add losses from shorts
                    aum += delta;
                } else {
                    currentAmmDeduction += delta;
                }
            }
        }

        aum = currentAmmDeduction > aum ? 0 : aum - currentAmmDeduction;
        return aumDeduction > aum ? 0 : aum - aumDeduction;
    }

    function getGlobalDelta(
        address _token,
        uint256 _price,
        uint256 _size,
        bool _isLong
    ) public view returns (uint256, bool) {
        uint256 averagePrice = _isLong
            ? getGlobalLongAveragePrice(_token)
            : getGlobalShortAveragePrice(_token);
        uint256 priceDelta = averagePrice > _price
            ? averagePrice - _price
            : _price - averagePrice;
        uint256 delta = (_size * priceDelta) / averagePrice;
        return (delta, _isLong ? averagePrice < _price : averagePrice > _price);
    }

    function getGlobalShortAveragePrice(address _token)
        public
        view
        returns (uint256)
    {
        IShortsTracker _shortsTracker = shortsTracker;
        if (
            address(_shortsTracker) == address(0) ||
            !_shortsTracker.isGlobalShortDataReady()
        ) {
            return vault.globalShortAveragePrices(_token);
        }

        uint256 _shortsTrackerAveragePriceWeight = shortsTrackerAveragePriceWeight;
        if (_shortsTrackerAveragePriceWeight == 0) {
            return vault.globalShortAveragePrices(_token);
        } else if (_shortsTrackerAveragePriceWeight == BASIS_POINTS_DIVISOR) {
            return _shortsTracker.globalShortAveragePrices(_token);
        }

        uint256 vaultAveragePrice = vault.globalShortAveragePrices(_token);
        uint256 shortsTrackerAveragePrice = _shortsTracker
            .globalShortAveragePrices(_token);

        return
            (vaultAveragePrice *
                (BASIS_POINTS_DIVISOR - _shortsTrackerAveragePriceWeight) +
                (shortsTrackerAveragePrice *
                    _shortsTrackerAveragePriceWeight)) / BASIS_POINTS_DIVISOR;
    }

    function getGlobalLongAveragePrice(address _token)
        public
        view
        returns (uint256)
    {
        return vault.globalLongAveragePrices(_token);
    }

    function estimatePlpOut(uint256 _amount)
        external
        view
        override
        returns (uint256 plpAmount)
    {
        uint256 aumInUsdp = getAumInUsdp(true);
        uint256 plpSupply = IERC20Upgradeable(plp).totalSupply();
        uint256 usdpAmount = vault.estimateUSDPOut(_amount);

        plpAmount = aumInUsdp == 0
            ? usdpAmount
            : (usdpAmount * plpSupply) / aumInUsdp;
    }

    function estimateTokenIn(uint256 _plpAmount)
        external
        view
        override
        returns (uint256 amountIn)
    {
        uint256 aumInUsdp = getAumInUsdp(true);
        uint256 plpSupply = IERC20Upgradeable(plp).totalSupply();

        uint256 usdpAmount = plpSupply == 0
            ? _plpAmount
            : (_plpAmount * aumInUsdp) / plpSupply;

        amountIn = vault.estimateTokenIn(usdpAmount);
    }

    function _addLiquidity(
        address _fundingAccount,
        address _account,
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minPlp
    ) private returns (uint256) {
        require(_amount > 0, "PlpManager: invalid _amount");

        // calculate aum before buyUSDP
        uint256 aumInUsdp = getAumInUsdp(true);
        uint256 plpSupply = IERC20Upgradeable(plp).totalSupply();

        IERC20Upgradeable(collateralToken).safeTransferFrom(
            _fundingAccount,
            address(vault),
            _amount
        );
        uint256 usdpAmount = vault.buyUSDP(address(this));
        require(usdpAmount >= _minUsdp, "PlpManager: insufficient USDP output");

        uint256 mintAmount = aumInUsdp == 0
            ? usdpAmount
            : (usdpAmount * plpSupply) / aumInUsdp;
        require(mintAmount >= _minPlp, "PlpManager: insufficient PLP output");

        IMintable(plp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(
            _account,
            _amount,
            aumInUsdp,
            plpSupply,
            usdpAmount,
            mintAmount
        );

        return mintAmount;
    }

    function _removeLiquidity(
        address _account,
        uint256 _plpAmount,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        require(_plpAmount > 0, "PlpManager: invalid _plpAmount");
        require(
            lastAddedAt[_account] + cooldownDuration <= block.timestamp,
            "PlpManager: cooldown duration not yet passed"
        );

        // calculate aum before sellUSDP
        uint256 aumInUsdp = getAumInUsdp(false);
        uint256 plpSupply = IERC20Upgradeable(plp).totalSupply();

        uint256 usdpAmount = (_plpAmount * aumInUsdp) / plpSupply;
        uint256 usdpBalance = IERC20Upgradeable(usdp).balanceOf(address(this));
        if (usdpAmount > usdpBalance) {
            IUSDP(usdp).mint(address(this), usdpAmount - usdpBalance);
        }

        IMintable(plp).burn(_account, _plpAmount);

        IERC20Upgradeable(usdp).safeTransfer(address(vault), usdpAmount);
        uint256 amountOut = vault.sellUSDP(_receiver);
        require(amountOut >= _minOut, "PlpManager: insufficient output");

        emit RemoveLiquidity(
            _account,
            _plpAmount,
            aumInUsdp,
            plpSupply,
            usdpAmount,
            amountOut
        );

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "PlpManager: forbidden");
    }
}
