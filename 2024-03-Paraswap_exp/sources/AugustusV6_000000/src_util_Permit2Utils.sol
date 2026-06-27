// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

/// @title Permit2Utils
/// @notice A contract containing common utilities for Permit2
contract Permit2Utils {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Permit2Failed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Permit2 address
    address public immutable PERMIT2; // solhint-disable-line var-name-mixedcase

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _permit2) {
        PERMIT2 = _permit2;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Parses data and executes permit2.permitTransferFrom, reverts if it fails
    function permit2TransferFrom(bytes calldata data, address recipient, uint256 amount) internal {
        address targetAddress = PERMIT2;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Get free memory pointer
            let ptr := mload(64)
            // Store function selector
            mstore(ptr, 0x30f28b7a00000000000000000000000000000000000000000000000000000000) // permitTransferFrom()
            // Copy data to memory
            calldatacopy(add(ptr, 4), data.offset, data.length)
            // Store recipient
            mstore(add(ptr, 132), recipient)
            // Store amount
            mstore(add(ptr, 164), amount)
            // Call permit2.permitTransferFrom and revert if call failed
            if iszero(call(gas(), targetAddress, 0, ptr, add(data.length, 4), 0, 0)) {
                mstore(0, 0x6b836e6b00000000000000000000000000000000000000000000000000000000) // Store error selector
                    // error Permit2Failed()
                revert(0, 4)
            }
        }
    }
}
