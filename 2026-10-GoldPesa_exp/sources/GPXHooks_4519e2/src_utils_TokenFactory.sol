// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
* @title Token Factory
* @notice This contract deterministically deploys a token contract (token0) using `CREATE2`,
*         ensuring that its resulting address is lexicographically less than the address of `token1`.
* @dev Useful in scenarios like Uniswap V4-style deployments, where the order of token addresses matters.
*/
contract TokenFactory {
    /// @notice The address of the reference token (token1) used for comparison
    address public token1;

    /// @dev Initializes the factory with the reference token address
    /// @param _token1 Address of token1 to compare against when deploying token0
    constructor(address _token1) {
        token1 = _token1;
    }

    /**
     * @notice Deploys token0 contract using CREATE2 with a salt that ensures its address < token1
     * @param bytecode The creation bytecode of the token0 contract
     * @return token0 The deployed address of the new contract
     */
    function deployToken0(bytes memory bytecode) internal returns (address token0) {
        bytes32 salt = _findValidSalt(bytecode);
        token0 = _deployWithCreate2(bytecode, salt);
    }

    /**
     * @dev Searches for a valid salt that results in an address less than token1
     * @param bytecode The creation bytecode of the contract to be deployed
     * @return bytes32 A bytes32 salt that produces a valid contract address
     */
    function _findValidSalt(bytes memory bytecode) internal view returns (bytes32) {
        for (uint256 i = 0; i < type(uint256).max; i++) {
            bytes32 salt = bytes32(i);
            address predictedAddress = _predictAddress(bytecode, salt);
            if (predictedAddress < token1) {
                return salt;
            }
        }
        revert("No valid salt found");
    }

    /**
     * @dev Deploys the contract using CREATE2 with the provided bytecode and salt
     * @param bytecode The creation bytecode of the contract
     * @param salt The salt to use for the deterministic deployment
     * @return address The deployed contract address
     */
    function _deployWithCreate2(bytes memory bytecode, bytes32 salt) internal returns (address) {
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
        return addr;
    }

    /**
     * @dev Computes the predicted address for a contract deployed via CREATE2
     * @param bytecode The creation bytecode of the contract
     * @param salt The salt to be used for the deterministic deployment
     * @return address The predicted contract address
     */
    function _predictAddress(bytes memory bytecode, bytes32 salt) internal view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        return address(uint160(uint256(hash)));
    }
}