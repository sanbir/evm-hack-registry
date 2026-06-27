pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {IVault} from "balancer-lbp-patch/v2-vault/contracts/interfaces/IVault.sol";
import {IERC20} from "balancer-lbp-patch/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";

import {NoProtocolFeeLiquidityBootstrappingPool} from
    "balancer-lbp-patch/v2-pool-weighted/contracts/smart/NoProtocolFeeLiquidityBootstrappingPool.sol";
import {WeightedMath} from "balancer-lbp-patch/v2-pool-weighted/contracts/WeightedMath.sol";

import {Errors, _revert, _require} from "balancer-lbp-patch/v2-solidity-utils/contracts/helpers/BalancerErrors.sol";

/**
 * @dev An implementation of NoProtocolLiquidityBootstrappingPool defined at this commit:
 *   https://github.com/balancer/balancer-v2-monorepo/commit/2e7998283713e1df445c15e368ca30fa2ee4a725
 *
 *  1. Track total amount of swap fees accrued per pool token.
 *  2. Swaps automatically enabled right at the start time. Only can be disabled by the owner
 *  3. Disable the pause/buffer window duration. Initially there for the balancer DAO to trigger an
 *     an emergency pause if needed after deploy. We dont need this as the pool code is battle tested.
 */
contract BazaarLBP is NoProtocolFeeLiquidityBootstrappingPool {
    IERC20[] private _tokens;
    uint256[] private _swapFeeAmounts;

    modifier onlyFactory() {
        _require(msg.sender == getOwner(), Errors.CALLER_IS_NOT_LBP_OWNER);
        _;
    }

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        //// Modified
        uint256[] memory startWeights,
        uint256[] memory endWeights,
        uint256 startTime,
        uint256 endTime,
        //// End
        uint256 swapFeePercentage
    )
        NoProtocolFeeLiquidityBootstrappingPool(
            vault,
            name,
            symbol,
            tokens,
            startWeights,
            swapFeePercentage,
            0, // pause window duration
            0, // buffer period duration,
            msg.sender,
            true // determined by start/end time unless disabled
        )
    {
        _require(startTime > block.timestamp && endTime > startTime, Errors.LOWER_GREATER_THAN_UPPER_TARGET);

        _tokens = tokens;
        _swapFeeAmounts = new uint256[](tokens.length);

        /**
         * Modified. configure the weight schedule upfront *
         */
        _startGradualWeightChange(startTime, endTime, _getNormalizedWeights(), endWeights);
    }

    /**
     * Additional Implementations *
     */
    function _processSwapFeeAmount(uint256 index, uint256 amount) internal override {
        _swapFeeAmounts[index] += amount;
    }

    function _tokenAddressToIndex(IERC20 token) internal view override returns (uint256) {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == token) return i;
        }

        _revert(Errors.INVALID_TOKEN);
    }

    // @devs swap fees are reset to 0 when exitLBP is called
    function resetSwapFees() external onlyFactory {
        for (uint256 i = 0; i < _swapFeeAmounts.length; i++) {
            _swapFeeAmounts[i] = 0;
        }
    }

    /**
     * Additional Views *
     */

    // @devs This returns the **total** swap fees accrued over the duration of the LBP, regardless of the joins that may
    //       have accrued over lifecycle of the LBP. The caller is responsible for ensuring state between exits when
    //       processing swap fees
    function totalAccruedSwapFeeAmounts() external view returns (uint256[] memory) {
        return _swapFeeAmounts;
    }

    // @devs implemented seperately to enforce the `view` modifier, ensuring no state is modified
    function querySwap(SwapRequest memory request, uint256 balanceTokenIn, uint256 balanceTokenOut)
        external
        view
        returns (uint256)
    {
        uint256 scalingFactorTokenIn = _scalingFactor(request.tokenIn);
        uint256 scalingFactorTokenOut = _scalingFactor(request.tokenOut);

        balanceTokenIn = _upscale(balanceTokenIn, scalingFactorTokenIn);
        balanceTokenOut = _upscale(balanceTokenOut, scalingFactorTokenOut);

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            // Fees are charged upfront
            request.amount = _subtractSwapFeeAmount(request.amount);

            // Swap
            request.amount = _upscale(request.amount, scalingFactorTokenIn);
            uint256 amountOut = WeightedMath._calcOutGivenIn(
                balanceTokenIn,
                _getNormalizedWeight(request.tokenIn),
                balanceTokenOut,
                _getNormalizedWeight(request.tokenOut),
                request.amount
            );

            // amountOut tokens are exiting the Pool, so we round down.
            return _downscaleDown(amountOut, scalingFactorTokenOut);
        } else {
            // Swap
            request.amount = _upscale(request.amount, scalingFactorTokenOut);
            uint256 amountIn = WeightedMath._calcInGivenOut(
                balanceTokenIn,
                _getNormalizedWeight(request.tokenIn),
                balanceTokenOut,
                _getNormalizedWeight(request.tokenOut),
                request.amount
            );

            // amountIn tokens are entering the Pool, so we round up
            amountIn = _downscaleUp(amountIn, scalingFactorTokenIn);

            // Fees are tacked onto the input
            return _addSwapFeeAmount(amountIn);
        }
    }
}
