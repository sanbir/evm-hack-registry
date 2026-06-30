// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IVTSwapHook {
    /// @notice Events
    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(address indexed user, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    function vault() external view returns (address);

    function getParamValue(bytes32 param) external view returns (uint256);

    /// @notice Whether currency0 is VT token
    function isToken0VT() external view returns (bool);

    function getVTAndTReserves() external view returns (uint256 reserveVT, uint256 reserveT);

    function getAmountOutTforVT(uint256 amountT) external view returns (uint256 amountVT);

    function getAmountOutVTforT(uint256 amountVT) external view returns (uint256 amountT);

}
