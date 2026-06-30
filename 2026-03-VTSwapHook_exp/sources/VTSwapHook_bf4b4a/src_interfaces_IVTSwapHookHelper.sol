// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IVTSwapHook} from "src/interfaces/IVTSwapHook.sol";

interface IVTSwapHookHelper {

    function doGetAmountIn(
        IVTSwapHook self, 
        uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min
    ) external view returns (uint256 amount0, uint256 amount1, uint256 shares);

    function doGetAmountOutTforVT(IVTSwapHook self, uint256 amountT) external view returns (uint256 amountVT);

    function doGetAmountOutVTforT(IVTSwapHook self, uint256 amountVT) external view returns (uint256 amountT);

    function doGetUnspecifiedAmount(
        IVTSwapHook self, bool zeroForOne, int256 amountSpecified
    ) external view returns (uint256 specifiedAmount, uint256 unspecifiedAmount);

}