// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IWETH } from "../interfaces/IWETH.sol";

/// @title WETHUtils
/// @notice A contract containing common utilities for WETH
contract WETHUtils {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev WETH address
    IWETH public immutable WETH;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _weth) {
        WETH = IWETH(_weth);
    }
}
