// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IAugustusRFQ } from "../interfaces/IAugustusRFQ.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

// Libraries
import { ERC20Utils } from "../libraries/ERC20Utils.sol";

// Utils
import { WETHUtils } from "./WETHUtils.sol";

/// @title AugustusRFQUtils
/// @notice A contract containing common utilities for AugustusRFQ swaps
abstract contract AugustusRFQUtils is WETHUtils {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using ERC20Utils for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when the msg.sender is not authorized to be the taker
    error UnauthorizedUser();

    /// @dev Emitted when the orders length is 0
    error InvalidOrdersLength();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev AugustusRFQ address
    IAugustusRFQ public immutable AUGUSTUS_RFQ; // solhint-disable-line var-name-mixedcase

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _augustusRFQ) {
        AUGUSTUS_RFQ = IAugustusRFQ(_augustusRFQ);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Check if the msg.sender is authorized to be the taker
    function _checkAuthorization(uint256 nonceAndMeta) internal view {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Parse nonceAndMeta
            if xor(and(nonceAndMeta, 0xffffffffffffffffffffffffffffffffffffffff), 0) {
                // If the taker is not 0, we check if the msg.sender is authorized
                if xor(and(nonceAndMeta, 0xffffffffffffffffffffffffffffffffffffffff), caller()) {
                    // The taker does not match the originalSender, revert
                    mstore(0, 0x02a43f8b00000000000000000000000000000000000000000000000000000000) // function
                        // selector for error UnauthorizedUser();
                    revert(0, 4)
                }
            }
        }
    }
}
