// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IUniswapV3SwapExactAmountIn } from "../../../interfaces/IUniswapV3SwapExactAmountIn.sol";

// Libraries
import { ERC20Utils } from "../../../libraries/ERC20Utils.sol";
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

// Types
import { UniswapV3Data } from "../../../AugustusV6Types.sol";

// Utils
import { UniswapV3Utils } from "../../../util/UniswapV3Utils.sol";
import { WETHUtils } from "../../../util/WETHUtils.sol";
import { Permit2Utils } from "../../../util/Permit2Utils.sol";

/// @title UniswapV3SwapExactAmountIn
/// @notice A contract for executing direct swapExactAmountIn on Uniswap V3
abstract contract UniswapV3SwapExactAmountIn is
    IUniswapV3SwapExactAmountIn,
    UniswapV3Utils,
    WETHUtils,
    Permit2Utils
{
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;
    using SafeCastLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                   SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IUniswapV3SwapExactAmountIn
    function swapExactAmountInOnUniswapV3(
        UniswapV3Data calldata uniData,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        // Dereference uniData
        IERC20 srcToken = uniData.srcToken;
        IERC20 destToken = uniData.destToken;
        uint256 amountIn = uniData.fromAmount;
        uint256 minAmountOut = uniData.toAmount;
        uint256 quotedAmountOut = uniData.quotedAmount;
        address payable beneficiary = uniData.beneficiary;
        bytes calldata pools = uniData.pools;

        // Check if toAmount is valid
        if (minAmountOut < 1) {
            revert InvalidToAmount();
        }

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Address that will pay for the swap
        address fromAddress = msg.sender;

        // Check if we need to wrap or permit
        if (srcToken.isETH(amountIn) == 0) {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
            }
        } else {
            // If it is ETH. wrap it to WETH
            WETH.deposit{ value: amountIn }();
            // Swap will be paid from this contract
            fromAddress = address(this);
        }

        // Execute swap
        receivedAmount = _callUniswapV3PoolsSwapExactAmountIn(amountIn.toInt256(), pools, fromAddress, permit);

        // Check if swap succeeded
        if (receivedAmount < minAmountOut) {
            revert InsufficientReturnAmount();
        }

        // Check if destToken is ETH and unwrap
        if (address(destToken) == address(ERC20Utils.ETH)) {
            // Unwrap WETH
            WETH.withdraw(receivedAmount);
            // Set receivedAmount to this contract's balance
            receivedAmount = address(this).balance;
        }

        // Process fees and transfer destToken to beneficiary
        return processSwapExactAmountInFeesAndTransfer(
            beneficiary, destToken, partnerAndFee, receivedAmount, quotedAmountOut
        );
    }
}
