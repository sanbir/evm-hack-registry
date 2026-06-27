pragma solidity 0.8.20;

/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SharwaFinance
 * Copyright (C) 2025 SharwaFinance
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 **/

import {IOneClickProxy} from "../../interfaces/oneClick/IOneClickProxy.sol";
import {IMarginAccount} from "../../interfaces/IMarginAccount.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {OneClickEphemeralSwapOutput} from "../swap_output/OneClickEphemeralSwapOutput.sol";
import {ILiquidityPool} from "../../interfaces/ILiquidityPool.sol";
import {IFacadeOutput} from "../../interfaces/oneClick/IFacadeOutput.sol";

contract FacadeOutput is AccessControl, IFacadeOutput {

    IOneClickProxy public oneClickProxy;
    IMarginAccount public marginAccount;
    OneClickEphemeralSwapOutput public oneClickEphemeralSwapOutput;

    address public weth;

    bytes32 public constant ONE_CLICK_CONTRACT_ROLE = keccak256("ONE_CLICK_CONTRACT_ROLE");

    constructor(
        IOneClickProxy _oneClickProxy,
        IMarginAccount _marginAccount,
        OneClickEphemeralSwapOutput _oneClickEphemeralSwapOutput,
        address _weth
    ) {
        oneClickProxy = _oneClickProxy;
        marginAccount = _marginAccount;   
        oneClickEphemeralSwapOutput = _oneClickEphemeralSwapOutput;
        weth = _weth;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ONLY ONE_CLICK_CONTRACT_ROLE FUNCTIONS

    /**
     * @notice Performs multiple output-based swaps and repays margin debt using the resulting tokens.
     *
     * @param marginAccountID   The ID of the margin account to operate on.
     * @param positionToken     The token representing the open position (collateral or borrowed asset).
     * @param tokenOut          The token to be used for debt repayment (typically the borrowed asset).
     * @param swapsData         An array of swap instructions, where each element must specify:
     *                            - tokenIn: the address of the input token to swap from,
     *                            - amountOut: the amount of tokenOut to receive from the swap,
     *                            - amountInMaximum: the maximum amount of tokenIn to spend for the swap.
     * @param repayAmount       The amount of `tokenOut` to repay.
     */
    function multiSwapOutputRepay(
        uint marginAccountID, 
        address positionToken,
        address tokenOut, 
        SwapOutputData[] memory swapsData, 
        uint repayAmount
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        uint balanceBefore = marginAccount.getErc20ByContract(marginAccountID, tokenOut);
        int256 changePositionSize = 0;
        int256 changeCollateralAmount = 0;
        for (uint i = 0; i < swapsData.length; i++) {
            SwapOutputData memory swap = swapsData[i]; 
            if (swap.amountOut != 0) {
                uint amountIn = oneClickEphemeralSwapOutput.swapOutput(marginAccountID, tokenOut, swap.tokenIn, swap.amountOut, swap.amountInMaximum);
                if (positionToken == swap.tokenIn) {
                    changePositionSize -= int256(amountIn);
                    changeCollateralAmount += int256(swap.amountOut);
                } else if (positionToken == tokenOut) {
                    changePositionSize += int256(swap.amountOut);
                    changeCollateralAmount -= int256(amountIn);
                }
            }
        }
        if (swapsData.length != 0) {
            oneClickProxy.changePosition(marginAccountID, positionToken, changePositionSize, changeCollateralAmount);
        }
        uint balanceAfter = marginAccount.getErc20ByContract(marginAccountID, tokenOut);
        uint repayAmountToUse;
        if (repayAmount != 0) {
            repayAmountToUse = repayAmount;
        } else {
            repayAmountToUse = balanceAfter - balanceBefore;
        }
        ILiquidityPool liuidityPool = ILiquidityPool(marginAccount.tokenToLiquidityPool(tokenOut));
        uint debt = liuidityPool.getDebtWithAccruedInterest(marginAccountID);
        if (debt != 0) {
            oneClickProxy.repay(marginAccountID, tokenOut, repayAmountToUse);
        }
    }

    function getAmountIn(
        address tokenIn,
        address tokenOut,
        uint amountOut
    ) public returns (uint amountIn) {
        if (amountOut == 0) {
            return 0;
        }
        amountIn = oneClickEphemeralSwapOutput.getAmountIn(tokenIn, tokenOut, amountOut);
        if (amountIn == 2) {
            return 0;
        }
    }

    function borrowSwapOutput(
        uint marginAccountID, 
        address positionToken,
        address tokenIn, 
        address tokenOut, 
        uint amountOut
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        (int256 positionSize,,,,) = oneClickProxy.getPosition(marginAccountID, positionToken);
        require(positionSize >= 0, "Short position exists");
        uint amountIn = getAmountIn(tokenOut, tokenIn, amountOut);
        oneClickProxy.borrow(marginAccountID, tokenIn, amountIn);
        oneClickEphemeralSwapOutput.swapOutput(marginAccountID, tokenOut, tokenIn, amountOut, amountIn);
        if (positionToken == tokenIn) {
            oneClickProxy.changePosition(marginAccountID, positionToken, -int256(amountIn), int256(amountOut));
        } else if (positionToken == tokenOut) {
            oneClickProxy.changePosition(marginAccountID, positionToken, int256(amountOut), -int256(amountIn));
        }
    }
}