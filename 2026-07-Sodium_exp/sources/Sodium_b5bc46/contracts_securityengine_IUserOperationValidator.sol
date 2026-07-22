// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import "../eip4337/interfaces/UserOperation.sol";

interface IUserOperationValidator {
    /**
     * Validate UserOperation from EIP-4337
     * @param userOp EIP4337 UserOperation
     * @return validationData
     * Indicates that there is no physical loss of the user's assets, similar to swap, bridge
     * 0 => safe
     *
     * Indicates that the calling dapp is authenticated.
     * 1 => medium security
     *
     * Indicates that the calling contract is not authenticated
     * 2 => nosafe
     */
    function validateUserOp(
        UserOperation calldata userOp
    ) external view returns (uint8 validationData);
}
