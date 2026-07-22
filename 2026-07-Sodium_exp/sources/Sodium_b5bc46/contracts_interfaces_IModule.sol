// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import {UserOperation} from "../eip4337/interfaces/UserOperation.sol";

// interface for modules to verify singatures signed over userOpHash
interface IModule {
    /**
     * @dev standard validateSignature for modules to validate and mark userOpHash as seen
     * @param userOp the operation that is about to be executed.
     * @param userOpHash hash of the user's request data. can be used as the basis for signature.
     * @return sigValidationResult sigAuthorizer to be passed back to trusting Account, aligns with validationData
     */
    function validateSignature(
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) external returns (uint256 sigValidationResult);
}
