// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v5/src/interfaces/IJBPayHook.sol";
import {IJBPrices} from "@bananapus/core-v5/src/interfaces/IJBPrices.sol";
import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v5/src/interfaces/IJBRulesetDataHook.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {IWETH9} from "./external/IWETH9.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook, IUniswapV3SwapCallback {
    event Swap(
        uint256 indexed projectId, uint256 amountToSwapWith, IUniswapV3Pool pool, uint256 amountReceived, address caller
    );
    event Mint(uint256 indexed projectId, uint256 leftoverAmount, uint256 tokenCount, address caller);
    event PoolAdded(uint256 indexed projectId, address indexed terminalToken, address pool, address caller);
    event TwapWindowChanged(uint256 indexed projectId, uint256 oldWindow, uint256 newWindow, address caller);

    function DIRECTORY() external view returns (IJBDirectory);
    function PRICES() external view returns (IJBPrices);
    function PROJECTS() external view returns (IJBProjects);
    function TOKENS() external view returns (IJBTokens);
    function MAX_TWAP_WINDOW() external view returns (uint256);
    function MIN_TWAP_WINDOW() external view returns (uint256);
    function TWAP_SLIPPAGE_DENOMINATOR() external view returns (uint256);
    function UNCERTAIN_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);

    function UNISWAP_V3_FACTORY() external view returns (address);
    function WETH() external view returns (IWETH9);

    function poolOf(uint256 projectId, address terminalToken) external view returns (IUniswapV3Pool pool);
    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);
    function twapWindowOf(uint256 projectId) external view returns (uint256 window);

    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint256 twapWindow,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool);
    function setTwapWindowOf(uint256 projectId, uint256 newWindow) external;
}
