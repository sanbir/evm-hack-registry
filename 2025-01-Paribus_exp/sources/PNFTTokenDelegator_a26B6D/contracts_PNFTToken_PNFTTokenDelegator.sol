// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "./PNFTTokenInterfaces.sol";
/**
 * @title Paribus PNFTDelegator Contract
 * @notice PNFTTokens which wrap an NFT underlying and delegate to an implementation
 * @author Paribus
 */
contract PNFTTokenDelegator is PNFTTokenDelegatorInterface {
    constructor(address underlying_,
        address comptroller_,
        string memory name_,
        string memory symbol_,
        address payable admin_,
        address implementation_,
        bytes memory becomeImplementationData) public {

        // Creator of the contract is admin during initialization
        admin = msg.sender;

        // First delegate gets to initialize the delegator (i.e. storage contract)
        delegateTo(implementation_, abi.encodeWithSignature("initialize(address,address,string,string)",
            underlying_,
            comptroller_,
            name_,
            symbol_));

        // New implementations always get set via the setter (post-initialize)
        _setImplementation(implementation_, false, becomeImplementationData);

        // Set the proper admin now that initialization is done
        require(admin_ != address(0), "invalid argument");
        admin = admin_;
    }

    /**
     * @notice Internal method to delegate execution to another contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param callee The contract to delegatecall
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateTo(address callee, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = callee.delegatecall(data);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize)
            }
        }

        require(returnData.length == 0 || (returnData.length >= 32 && uint256(abi.decode(returnData, (uint256))) != 0), "delegate call failed");
        return returnData;
    }

    /**
     * @notice Delegates execution to the implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateToImplementation(bytes memory data) public returns (bytes memory) {
        return delegateTo(implementation, data);
    }

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param newImplementation The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address newImplementation, bool allowResign, bytes memory becomeImplementationData) public {
        require(msg.sender == admin, "only admin");
        // Perform a low-level call to check if isPNFTToken() exists and returns true
        (bool success,) = newImplementation.staticcall(
            abi.encodeWithSignature("isPNFTToken()")
        );

        require(success, "PNFTToken not supported");

        if (allowResign) {
            delegateToImplementation(abi.encodeWithSignature("_resignImplementation()"));
        }

        address oldImplementation = implementation;
        implementation = newImplementation;

        delegateToImplementation(abi.encodeWithSignature("_becomeImplementation(bytes)", becomeImplementationData));

        emit NewImplementation(oldImplementation, implementation);
    }

    /**
     * @notice Delegates execution to an implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     */
    function() external payable {
        if (msg.value > 0) {
            // handle transfer ether from sudoswap during NFT token liquidation
            // nothing really to do here
            return;
        }

        // delegate all other functions to current implementation
        (bool success, ) = implementation.delegatecall(msg.data);

        assembly {
            let free_mem_ptr := mload(0x40)
            returndatacopy(free_mem_ptr, 0, returndatasize)

            switch success
            case 0 { revert(free_mem_ptr, returndatasize) }
            default { return (free_mem_ptr, returndatasize) }
        }
    }
}
