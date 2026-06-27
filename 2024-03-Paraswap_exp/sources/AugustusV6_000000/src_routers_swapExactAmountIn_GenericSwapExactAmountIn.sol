// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Contracts
import { GenericUtils } from "../../util/GenericUtils.sol";

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IGenericSwapExactAmountIn } from "../../interfaces/IGenericSwapExactAmountIn.sol";

// Libraries
import { ERC20Utils } from "../../libraries/ERC20Utils.sol";

// Types
import { GenericData } from "../../AugustusV6Types.sol";

// Utils
import { Permit2Utils } from "../../util/Permit2Utils.sol";

/// @title GenericSwapExactAmountIn
/// @notice Router for executing generic swaps with exact amount in through an executor
abstract contract GenericSwapExactAmountIn is IGenericSwapExactAmountIn, GenericUtils, Permit2Utils {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                          SWAP EXACT AMOUNT IN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGenericSwapExactAmountIn
    function swapExactAmountIn(
        address executor,
        GenericData calldata swapData,
        uint256 partnerAndFee,
        bytes calldata permit,
        bytes calldata executorData
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        // Dereference swapData
        IERC20 destToken = swapData.destToken;
        IERC20 srcToken = swapData.srcToken;
        uint256 amountIn = swapData.fromAmount;
        uint256 minAmountOut = swapData.toAmount;
        uint256 quotedAmountOut = swapData.quotedAmount;
        address payable beneficiary = swapData.beneficiary;

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Check if toAmount is valid
        if (minAmountOut < 1) {
            revert InvalidToAmount();
        }

        // Check if srcToken is ETH
        if (srcToken.isETH(amountIn) == 0) {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            // and if it is >= 257 we execute permit2
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
                srcToken.safeTransferFrom(msg.sender, executor, amountIn);
            } else {
                // Otherwise Permit2.permitTransferFrom
                permit2TransferFrom(permit, executor, amountIn);
            }
        }

        // Execute swap
        _callSwapExactAmountInExecutor(executor, executorData, amountIn);

        // Check balance after swap
        receivedAmount = destToken.getBalance(address(this));

        // Check if swap succeeded
        if (receivedAmount < minAmountOut) {
            revert InsufficientReturnAmount();
        }

        // Process fees and transfer destToken to beneficiary
        return processSwapExactAmountInFeesAndTransfer(
            beneficiary, destToken, partnerAndFee, receivedAmount, quotedAmountOut
        );
    }
}
