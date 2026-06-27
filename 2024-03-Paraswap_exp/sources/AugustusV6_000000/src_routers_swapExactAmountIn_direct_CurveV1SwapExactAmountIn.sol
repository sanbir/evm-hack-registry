// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { ICurveV1SwapExactAmountIn } from "../../../interfaces/ICurveV1SwapExactAmountIn.sol";

// Libraries
import { ERC20Utils } from "../../../libraries/ERC20Utils.sol";

// Types
import { CurveV1Data } from "../../../AugustusV6Types.sol";

// Utils
import { AugustusFees } from "../../../fees/AugustusFees.sol";
import { WETHUtils } from "../../../util/WETHUtils.sol";
import { Permit2Utils } from "../../../util/Permit2Utils.sol";

/// @title CurveV1SwapExactAmountIn
/// @notice A contract for executing direct CurveV1 swaps
abstract contract CurveV1SwapExactAmountIn is ICurveV1SwapExactAmountIn, AugustusFees, WETHUtils, Permit2Utils {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                          SWAP EXACT AMOUNT IN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICurveV1SwapExactAmountIn
    function swapExactAmountInOnCurveV1(
        CurveV1Data calldata curveV1Data,
        uint256 partnerAndFee,
        bytes calldata permit
    )
        external
        payable
        returns (uint256 receivedAmount, uint256 paraswapShare, uint256 partnerShare)
    {
        // Dereference curveV1Data
        IERC20 srcToken = curveV1Data.srcToken;
        IERC20 destToken = curveV1Data.destToken;
        uint256 amountIn = curveV1Data.fromAmount;
        uint256 minAmountOut = curveV1Data.toAmount;
        uint256 quotedAmountOut = curveV1Data.quotedAmount;
        address payable beneficiary = curveV1Data.beneficiary;
        uint256 curveAssets = curveV1Data.curveAssets;
        uint256 curveData = curveV1Data.curveData;

        // Check if toAmount is valid
        if (minAmountOut < 1) {
            revert InvalidToAmount();
        }

        // Check if beneficiary is valid
        if (beneficiary == address(0)) {
            beneficiary = payable(msg.sender);
        }

        // Decode curveData
        // 160 bits for curve exchange address
        // 1 bit for approve flag
        // 2 bits for wrap flag
        // 2 bits for swap type flag

        address exchange;
        uint256 approveFlag;
        uint256 wrapFlag;
        uint256 swapType;

        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            exchange := and(curveData, 0xffffffffffffffffffffffffffffffffffffffff)
            approveFlag := and(shr(160, curveData), 1)
            wrapFlag := and(shr(161, curveData), 3)
            swapType := and(shr(163, curveData), 3)
        }

        // Check if srcToken is ETH
        // Transfer srcToken to augustus if not ETH
        if (srcToken.isETH(amountIn) == 0) {
            // Check the lenght of the permit field,
            // if < 257 and > 0 we should execute regular permit
            // and if it is >= 257 we execute permit2
            if (permit.length < 257) {
                // Permit if needed
                if (permit.length > 0) {
                    srcToken.permit(permit);
                }
                srcToken.safeTransferFrom(msg.sender, address(this), amountIn);
            } else {
                // Otherwise Permit2.permitTransferFrom
                permit2TransferFrom(permit, address(this), amountIn);
            }
            // Check if approve flag is set
            if (approveFlag == 1) {
                // Approve exchange
                srcToken.approve(exchange);
            }
        } else {
            // Check if approve flag is set
            if (approveFlag == 1) {
                // Approve exchange
                IERC20(WETH).approve(exchange);
            }
        }

        // Execute swap
        _executeSwapOnCurveV1(exchange, wrapFlag, swapType, curveAssets, amountIn);

        // Check balance after swap and unwrap if needed
        if (wrapFlag == 2) {
            // Received amount is WETH balance
            receivedAmount = IERC20(WETH).getBalance(address(this));
            // Unwrap WETH
            WETH.withdraw(receivedAmount - 1);
            // Set receivedAmount to this contract's balance
            receivedAmount = address(this).balance;
        } else {
            // Received amount is destToken balance
            receivedAmount = destToken.getBalance(address(this));
        }

        // Check if swap succeeded
        if (receivedAmount < minAmountOut) {
            revert InsufficientReturnAmount();
        }

        // Process fees and transfer destToken to beneficiary
        return processSwapExactAmountInFeesAndTransfer(
            beneficiary, destToken, partnerAndFee, receivedAmount, quotedAmountOut
        );
    }

    /*//////////////////////////////////////////////////////////////
                                PRIVATE
    //////////////////////////////////////////////////////////////*/

    function _executeSwapOnCurveV1(
        address exchange,
        uint256 wrapFlag,
        uint256 swapType,
        uint256 curveAssets,
        uint256 fromAmount
    )
        private
    {
        // Load WETH address
        address weth = address(WETH);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Load free memory pointer
            let ptr := mload(64)

            //-----------------------------------------------------------------------------------
            // Wrap ETH if needed
            //-----------------------------------------------------------------------------------

            // Check if wrap src flag is set
            if eq(wrapFlag, 1) {
                // Prepare call data for WETH.deposit()

                // Store function selector and
                mstore(ptr, 0xd0e30db000000000000000000000000000000000000000000000000000000000) // deposit()

                // Perform the external call with the prepared calldata
                // Check the outcome of the call and handle failure
                if iszero(call(gas(), weth, callvalue(), ptr, 4, 0, 0)) {
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }
            }

            //-----------------------------------------------------------------------------------
            // Execute swap
            //-----------------------------------------------------------------------------------

            // Prepare call data for external call

            // Check swap type
            switch swapType
            // 0x01 for EXCHANGE_UNDERLYING
            case 0x01 {
                // Store function selector for function exchange_underlying(int128,int128,uint256,uint256)
                mstore(ptr, 0xa6417ed600000000000000000000000000000000000000000000000000000000) // store selector
                mstore(add(ptr, 4), shr(128, curveAssets)) // store index i
                mstore(add(ptr, 36), and(curveAssets, 0xffffffffffffffffffffffffffffffff)) // store index j
                mstore(add(ptr, 68), fromAmount) // store fromAmount
                mstore(add(ptr, 100), 1) // store 1
                // Perform the external call with the prepared calldata
                // Check the outcome of the call and handle failure
                if iszero(call(gas(), exchange, 0, ptr, 132, 0, 0)) {
                    // The call failed; we retrieve the exact error message and revert with it
                    returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                    revert(0, returndatasize()) // Revert with the error message
                }
            }
            // 0x00(default) for EXCHANGE
            default {
                // check send eth wrap flag
                switch eq(wrapFlag, 0x03)
                // if it is not set, store selector for function exchange(int128,int128,uint256,uint256)
                case 1 {
                    mstore(ptr, 0x3df0212400000000000000000000000000000000000000000000000000000000) // store selector
                    mstore(add(ptr, 4), shr(128, curveAssets)) // store index i
                    mstore(add(ptr, 36), and(curveAssets, 0xffffffffffffffffffffffffffffffff)) // store index j
                    mstore(add(ptr, 68), fromAmount) // store fromAmount
                    mstore(add(ptr, 100), 1) // store 1
                    // Perform the external call with the prepared calldata
                    // Check the outcome of the call and handle failure
                    if iszero(call(gas(), exchange, callvalue(), ptr, 132, 0, 0)) {
                        // The call failed; we retrieve the exact error message and revert with it
                        returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                        revert(0, returndatasize()) // Revert with the error message
                    }
                }
                // if it is set, store selector for function exchange(int128,int128,uint256,uint256)
                default {
                    mstore(ptr, 0x3df0212400000000000000000000000000000000000000000000000000000000) // store selector
                    mstore(add(ptr, 4), shr(128, curveAssets)) // store index i
                    mstore(add(ptr, 36), and(curveAssets, 0xffffffffffffffffffffffffffffffff)) // store index j
                    mstore(add(ptr, 68), fromAmount) // store fromAmount
                    mstore(add(ptr, 100), 1) // store 1
                    // Perform the external call with the prepared calldata
                    // Check the outcome of the call and handle failure
                    if iszero(call(gas(), exchange, 0, ptr, 132, 0, 0)) {
                        // The call failed; we retrieve the exact error message and revert with it
                        returndatacopy(0, 0, returndatasize()) // Copy the error message to the start of memory
                        revert(0, returndatasize()) // Revert with the error message
                    }
                }
            }
        }
    }
}
