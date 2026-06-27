// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.17;

import "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "lib/v3-core/contracts/libraries/FullMath.sol";
import "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "./UniHelper.sol";
import "./Perp.sol";
import "./DataType.sol";
import "./Constants.sol";
import "./math/Math.sol";
import "../PriceFeed.sol";

/// @title PositionCalculator library
/// @notice Provides functions for calculating portfolio value and margin requirements
library PositionCalculator {
    using ScaledAsset for ScaledAsset.AssetStatus;
    using SafeCast for uint256;

    error NotSafe();

    uint256 internal constant RISK_RATIO_ONE = 1e8;

    struct PositionParams {
        // x^0
        int256 amountStable;
        // 2x^0.5
        int256 amountSqrt;
        // x^1
        int256 amountUnderlying;
    }

    function isLiquidatable(
        DataType.PairStatus memory pairStatus,
        DataType.Vault memory _vault,
        DataType.FeeAmount memory FeeAmount
    ) internal view returns (bool _isLiquidatable, int256 minMargin, int256 vaultValue, uint256 twap) {
        bool hasPosition;

        (minMargin, vaultValue, hasPosition, twap) = calculateMinDeposit(pairStatus, _vault, FeeAmount);

        bool isSafe = vaultValue >= minMargin && _vault.margin >= 0;

        _isLiquidatable = !isSafe && hasPosition;
    }

    function checkSafe(
        DataType.PairStatus memory pairStatus,
        DataType.Vault memory _vault,
        DataType.FeeAmount memory FeeAmount
    ) internal view returns (int256 minMargin) {
        bool isSafe;

        (minMargin, isSafe,) = getIsSafe(pairStatus, _vault, FeeAmount);

        if (!isSafe) {
            revert NotSafe();
        }
    }

    function getIsSafe(
        DataType.PairStatus memory pairStatus,
        DataType.Vault memory _vault,
        DataType.FeeAmount memory FeeAmount
    ) internal view returns (int256 minMargin, bool isSafe, bool hasPosition) {
        int256 vaultValue;

        (minMargin, vaultValue, hasPosition,) = calculateMinDeposit(pairStatus, _vault, FeeAmount);

        isSafe = vaultValue >= minMargin && _vault.margin >= 0;
    }

    function calculateMinDeposit(
        DataType.PairStatus memory pairStatus,
        DataType.Vault memory vault,
        DataType.FeeAmount memory feeAmount
    ) internal view returns (int256 minMargin, int256 vaultValue, bool hasPosition, uint256 twap) {
        int256 minValue;
        uint256 debtValue;

        twap = getSqrtIndexPrice(pairStatus);

        (minValue, vaultValue, debtValue, hasPosition) = calculateMinValue(
            vault.margin, getPositionWithFeeAmount(vault.openPosition, feeAmount), twap, pairStatus.riskParams.riskRatio
        );

        int256 minMinValue = (calculateRequiredCollateralWithDebt(pairStatus.riskParams.debtRiskRatio) * debtValue).toInt256() / 1e6;

        minMargin = vaultValue - minValue + minMinValue;

        if (hasPosition && minMargin < Constants.MIN_MARGIN_AMOUNT) {
            minMargin = Constants.MIN_MARGIN_AMOUNT;
        }
    }

    function calculateRequiredCollateralWithDebt(uint128 debtRiskRatio) internal pure returns (uint256) {
        if(debtRiskRatio == 0) {
            return Constants.BASE_MIN_COLLATERAL_WITH_DEBT;
        } else {
            return debtRiskRatio;
        }
    }

    /**
     * @notice Calculates min value of the vault.
     * @param marginAmount The target vault for calculation
     * @param positionParams The position parameters
     * @param sqrtPrice The square root of time-weighted average price
     * @param riskRatio risk ratio of price
     */
    function calculateMinValue(
        int256 marginAmount,
        PositionParams memory positionParams,
        uint256 sqrtPrice,
        uint256 riskRatio
    ) internal pure returns (int256 minValue, int256 vaultValue, uint256 debtValue, bool hasPosition) {
        minValue += calculateMinValue(sqrtPrice, positionParams, riskRatio);

        vaultValue += calculateValue(sqrtPrice, positionParams);

        debtValue += calculateSquartDebtValue(sqrtPrice, positionParams);

        hasPosition = hasPosition || getHasPositionFlag(positionParams);

        minValue += marginAmount;
        vaultValue += marginAmount;
    }

    function getHasPosition(DataType.Vault memory _vault) internal pure returns (bool hasPosition) {
        Perp.UserStatus memory userStatus = _vault.openPosition;

        hasPosition = hasPosition || getHasPositionFlag(getPosition(userStatus));
    }

    function getSqrtIndexPrice(DataType.PairStatus memory pairStatus) internal view returns (uint256 sqrtPriceX96) {
        if (pairStatus.priceFeed != address(0)) {
            return PriceFeed(pairStatus.priceFeed).getSqrtPrice();
        } else {
            return UniHelper.convertSqrtPrice(
                UniHelper.getSqrtTWAP(pairStatus.sqrtAssetStatus.uniswapPool), pairStatus.isQuoteZero
            );
        }
    }

    function getPositionWithFeeAmount(Perp.UserStatus memory perpUserStatus, DataType.FeeAmount memory feeAmount)
        internal
        pure
        returns (PositionParams memory positionParams)
    {
        return PositionParams(
            perpUserStatus.perp.entryValue + perpUserStatus.sqrtPerp.entryValue + feeAmount.feeAmountQuote,
            perpUserStatus.sqrtPerp.amount,
            perpUserStatus.perp.amount + feeAmount.feeAmountBase
        );
    }

    function getPosition(Perp.UserStatus memory _perpUserStatus)
        internal
        pure
        returns (PositionParams memory positionParams)
    {
        return PositionParams(
            _perpUserStatus.perp.entryValue + _perpUserStatus.sqrtPerp.entryValue,
            _perpUserStatus.sqrtPerp.amount,
            _perpUserStatus.perp.amount
        );
    }

    function getHasPositionFlag(PositionParams memory _positionParams) internal pure returns (bool) {
        return _positionParams.amountSqrt != 0 || _positionParams.amountUnderlying != 0;
    }

    /**
     * @notice Calculates min position value in the range `p/r` to `rp`.
     * MinValue := Min(v(rp), v(p/r), v((b/a)^2))
     * where `a` is underlying asset amount, `b` is Sqrt perp amount
     * and `c` is Stable asset amount.
     * r is risk parameter.
     */
    function calculateMinValue(uint256 _sqrtPrice, PositionParams memory _positionParams, uint256 _riskRatio)
        internal
        pure
        returns (int256 minValue)
    {
        minValue = type(int256).max;

        uint256 upperPrice = _sqrtPrice * _riskRatio / RISK_RATIO_ONE;
        uint256 lowerPrice = _sqrtPrice * RISK_RATIO_ONE / _riskRatio;

        {
            int256 v = calculateValue(upperPrice, _positionParams);
            if (v < minValue) {
                minValue = v;
            }
        }

        {
            int256 v = calculateValue(lowerPrice, _positionParams);
            if (v < minValue) {
                minValue = v;
            }
        }

        if (_positionParams.amountSqrt < 0 && _positionParams.amountUnderlying > 0) {
            // amountSqrt * 2^96 is fits in 256 bits
            uint256 minSqrtPrice =
                (uint256(-_positionParams.amountSqrt) * Constants.Q96) / uint256(_positionParams.amountUnderlying);

            if (lowerPrice < minSqrtPrice && minSqrtPrice < upperPrice) {
                int256 v = calculateValue(minSqrtPrice, _positionParams);

                if (v < minValue) {
                    minValue = v;
                }
            }
        }
    }

    /**
     * @notice Calculates position value.
     * PositionValue = a * x+2 * b * sqrt(x) + c.
     * where `a` is underlying asset amount, `b` is liquidity amount of Uni LP Position
     * and `c` is Stable asset amount
     */
    function calculateValue(uint256 _sqrtPrice, PositionParams memory _positionParams) internal pure returns (int256) {
        uint256 price = Math.calSqrtPriceToPrice(_sqrtPrice);

        return Math.fullMulDivInt256(_positionParams.amountUnderlying, price, Constants.Q96)
            + Math.fullMulDivInt256(2 * _positionParams.amountSqrt, _sqrtPrice, Constants.Q96)
            + _positionParams.amountStable;
    }

    function calculateSquartDebtValue(uint256 _sqrtPrice, PositionParams memory positionParams)
        internal
        pure
        returns (uint256)
    {
        int256 squartPosition = positionParams.amountSqrt;

        if (squartPosition > 0) {
            return 0;
        }

        return (2 * (uint256(-squartPosition) * _sqrtPrice) >> Constants.RESOLUTION);
    }
}
