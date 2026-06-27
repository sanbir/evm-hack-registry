// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IAugustusRFQRouter } from "../../interfaces/IAugustusRFQRouter.sol";

// Libraries
import { ERC20Utils } from "../../libraries/ERC20Utils.sol";

// Types
import { AugustusRFQData, OrderInfo } from "../../AugustusV6Types.sol";

// Utils
import { AugustusRFQUtils } from "../../util/AugustusRFQUtils.sol";
import { Permit2Utils } from "../../util/Permit2Utils.sol";

/// @title AugustusRFQRouter
/// @notice A contract for executing direct AugustusRFQ swaps
abstract contract AugustusRFQRouter is IAugustusRFQRouter, AugustusRFQUtils, Permit2Utils {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                             TRY BATCH FILL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAugustusRFQRouter
    // solhint-disable-next-line code-complexity
    function swapExactAmountInOutOnAugustusRFQTryBatchFill(
        AugustusRFQData calldata data,
        OrderInfo[] calldata orders,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 spentAmount, uint256 receivedAmount)
    {
        // Dereference data
        address payable beneficiary = data.beneficiary;
        uint256 ordersLength = orders.length;
        uint256 fromAmount = data.fromAmount;
        uint256 toAmount = data.toAmount;
        uint8 wrapApproveDirection = data.wrapApproveDirection;

        // Decode wrapApproveDirection
        uint8 wrap = wrapApproveDirection & 3;
        uint8 approve = (wrapApproveDirection >> 2) & 1;
        uint8 direction = (wrapApproveDirection >> 3) & 1;

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Check if toAmount is valid
        if (toAmount < 1) {
            revert InvalidToAmount();
        }

        // Check if ordersLength is valid
        if (ordersLength < 1) {
            revert InvalidOrdersLength();
        }

        // Check if msg.sender is authorized to be the taker for all orders
        for (uint256 i = 0; i < ordersLength; ++i) {
            _checkAuthorization(orders[i].order.nonceAndMeta);
        }

        // Dereference srcToken and destToken
        IERC20 srcToken = IERC20(orders[0].order.takerAsset);
        IERC20 destToken = IERC20(orders[0].order.makerAsset);

        // Check if we need to wrap or permit
        if (wrap != 1) {
            // If msg.value is not 0, revert
            if (msg.value > 0) {
                revert IncorrectEthAmount();
            }

            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            // and if it is >= 257 we execute permit2
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
                srcToken.safeTransferFrom(msg.sender, address(this), fromAmount);
            } else {
                // Otherwise Permit2.permitTransferFrom
                permit2TransferFrom(permit, address(this), fromAmount);
            }
        } else {
            // Check if msg.value is equal to fromAmount
            if (fromAmount != msg.value) {
                revert IncorrectEthAmount();
            }
            // If it is ETH. wrap it to WETH
            WETH.deposit{ value: fromAmount }();
        }

        if (approve == 1) {
            // Approve srcToken to AugustusRFQ
            srcToken.approve(address(AUGUSTUS_RFQ));
        }

        // Check if we need to execute a swapExactAmountIn or a swapExactAmountOut
        if (direction == 0) {
            // swapExactAmountIn
            // Unwrap WETH if needed
            if (wrap == 2) {
                // Execute tryBatchFillOrderTakerAmount
                AUGUSTUS_RFQ.tryBatchFillOrderTakerAmount(orders, fromAmount, address(this));
                // Check received amount
                receivedAmount = IERC20(WETH).getBalance(address(this));
                // Check if swap succeeded
                if (receivedAmount < toAmount) {
                    revert InsufficientReturnAmount();
                }
                // Unwrap WETH
                WETH.withdraw(--receivedAmount);
                // Transfer ETH to beneficiary
                ERC20Utils.ETH.safeTransfer(beneficiary, receivedAmount);
            } else {
                // Check balance of beneficiary before swap
                uint256 beforeBalance = destToken.getBalance(beneficiary);

                // Execute tryBatchFillOrderTakerAmount
                AUGUSTUS_RFQ.tryBatchFillOrderTakerAmount(orders, fromAmount, beneficiary);

                // set receivedAmount to afterBalance - beforeBalance
                receivedAmount = destToken.getBalance(beneficiary) - beforeBalance;

                // Check if swap succeeded
                if (receivedAmount < toAmount) {
                    revert InsufficientReturnAmount();
                }
            }

            // Return spentAmount and receivedAmount
            return (fromAmount, receivedAmount);
        } else {
            // swapExactAmountOut
            // Unwrap WETH if needed
            if (wrap == 2) {
                // Execute tryBatchFillOrderMakerAmount
                AUGUSTUS_RFQ.tryBatchFillOrderMakerAmount(orders, toAmount, address(this));
                // Check remaining WETH balance
                receivedAmount = IERC20(WETH).getBalance(address(this));
                // Unwrap WETH
                WETH.withdraw(--receivedAmount);
                // Transfer ETH to beneficiary
                ERC20Utils.ETH.safeTransfer(beneficiary, receivedAmount);
                // Set toAmount to receivedAmount
                toAmount = receivedAmount;
            } else {
                // Execute tryBatchFillOrderMakerAmount
                AUGUSTUS_RFQ.tryBatchFillOrderMakerAmount(orders, toAmount, beneficiary);
            }

            // Check remaining amount
            uint256 remainingAmount = srcToken.getBalance(address(this));

            // Send remaining srcToken to msg.sender
            if (remainingAmount > 1) {
                // If srcToken was ETH
                if (wrap == 1) {
                    // Unwrap WETH
                    WETH.withdraw(--remainingAmount);
                    // Transfer ETH to msg.sender
                    ERC20Utils.ETH.safeTransfer(msg.sender, remainingAmount);
                } else {
                    // Transfer remaining srcToken to msg.sender
                    srcToken.safeTransfer(msg.sender, --remainingAmount);
                }
            }

            // Return spentAmount and receivedAmount
            return (fromAmount - remainingAmount, toAmount);
        }
    }
}
