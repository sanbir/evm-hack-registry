// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title IWETH
/// @notice An interface for WETH IERC20
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
