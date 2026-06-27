// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.26;

interface IRegistryContract {
    /// @notice Get the address of the contract
    /// @param name The name of the contract in bytes32
    /// @return contractAddress The address of the contract
    function getContract(bytes32 name) external view returns (address);

    /// @notice Set the address of the contract
    /// @param name The name of the contract in bytes32
    /// @param contractAddress The address of the contract
    function setContract(bytes32 name, address contractAddress) external;
}
