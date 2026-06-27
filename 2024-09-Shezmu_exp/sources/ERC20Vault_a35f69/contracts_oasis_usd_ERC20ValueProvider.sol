// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol';

import '../../utils/AccessControlUpgradeable.sol';
import '../../utils/RateLib.sol';
import '../../interfaces/IChainlinkV3Aggregator.sol';

abstract contract ERC20ValueProvider is
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using RateLib for RateLib.Rate;

    error InvalidAmount(uint256 amount);
    error ZeroAddress();
    error InvalidOracleResults();

    event NewBaseCreditLimitRate(RateLib.Rate rate);
    event NewBaseLiquidationLimitRate(RateLib.Rate rate);

    /// @notice The token oracles aggregator
    IChainlinkV3Aggregator public aggregator;

    /// @notice The token address
    IERC20MetadataUpgradeable public token;

    RateLib.Rate public baseCreditLimitRate;
    RateLib.Rate public baseLiquidationLimitRate;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _aggregator The token oracles aggregator
    /// @param _token The token address
    /// @param _baseCreditLimitRate The base credit limit rate
    /// @param _baseLiquidationLimitRate The base liquidation limit rate
    function __initialize(
        IChainlinkV3Aggregator _aggregator,
        IERC20MetadataUpgradeable _token,
        RateLib.Rate calldata _baseCreditLimitRate,
        RateLib.Rate calldata _baseLiquidationLimitRate
    ) internal onlyInitializing {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (address(_aggregator) == address(0)) revert ZeroAddress();

        _validateRateBelowOne(_baseCreditLimitRate);
        _validateRateBelowOne(_baseLiquidationLimitRate);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        aggregator = _aggregator;
        token = _token;
        baseCreditLimitRate = _baseCreditLimitRate;
        baseLiquidationLimitRate = _baseLiquidationLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The credit limit rate
    function getCreditLimitRate(
        address _owner,
        uint256 _colAmount
    ) public view returns (RateLib.Rate memory) {
        return baseCreditLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The liquidation limit rate
    function getLiquidationLimitRate(
        address _owner,
        uint256 _colAmount
    ) public view returns (RateLib.Rate memory) {
        return baseLiquidationLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The credit limit for collateral amount
    function getCreditLimitUSD(
        address _owner,
        uint256 _colAmount
    ) external view returns (uint256) {
        RateLib.Rate memory _creditLimitRate = getCreditLimitRate(
            _owner,
            _colAmount
        );
        return _creditLimitRate.calculate(getPriceUSD(_colAmount));
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The liquidation limit for collateral amount
    function getLiquidationLimitUSD(
        address _owner,
        uint256 _colAmount
    ) external view returns (uint256) {
        RateLib.Rate memory _liquidationLimitRate = getLiquidationLimitRate(
            _owner,
            _colAmount
        );
        return _liquidationLimitRate.calculate(getPriceUSD(_colAmount));
    }

    /// @return The value for the collection, in USD.
    function getPriceUSD(uint256 colAmount) public view returns (uint256) {
        uint256 price = getPriceUSD();
        return (price * colAmount) / (10 ** token.decimals());
    }

    /// @return The value for the collection, in USD.
    function getPriceUSD() public view virtual returns (uint256) {
        (, int256 answer, , uint256 timestamp, ) = aggregator.latestRoundData();

        if (answer == 0 || timestamp == 0) revert InvalidOracleResults();

        uint8 decimals = aggregator.decimals();

        unchecked {
            //converts the answer to have 18 decimals
            return
                decimals > 18
                    ? uint256(answer) / 10 ** (decimals - 18)
                    : uint256(answer) * 10 ** (18 - decimals);
        }
    }

    function setBaseCreditLimitRate(
        RateLib.Rate memory _baseCreditLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_baseCreditLimitRate);

        baseCreditLimitRate = _baseCreditLimitRate;

        emit NewBaseCreditLimitRate(_baseCreditLimitRate);
    }

    function setBaseLiquidationLimitRate(
        RateLib.Rate memory _liquidationLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_liquidationLimitRate);

        baseLiquidationLimitRate = _liquidationLimitRate;

        emit NewBaseLiquidationLimitRate(_liquidationLimitRate);
    }

    /// @dev Validates a rate. The denominator must be greater than zero and greater than or equal to the numerator.
    /// @param _rate The rate to validate
    function _validateRateBelowOne(RateLib.Rate memory _rate) internal pure {
        if (!_rate.isValid() || _rate.isAboveOne())
            revert RateLib.InvalidRate();
    }
}
