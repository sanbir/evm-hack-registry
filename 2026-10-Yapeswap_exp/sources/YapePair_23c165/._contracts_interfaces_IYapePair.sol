// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import {IUniswapV2Pair} from "../helpers/uni-v2/interfaces/IUniswapV2Pair.sol";

interface IYapePair is IUniswapV2Pair {
    function updateRegistry() external;

    function setFarmingRatio(uint256 min, uint256 max) external;

    function migrate(address token) external returns (uint256);

    function migrate(address token, uint256 amount) external returns (uint256);

    function migrate(
        address token,
        uint256 amount,
        uint256 maxMigrationLoss
    ) external returns (uint256);
}
