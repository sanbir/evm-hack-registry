// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

library Constants {
    /**
     * @notice The address interpreted as native token of the chain.
     */
    address public constant NATIVE_TOKEN = address(0);

    uint256 public constant PROTOCOL_DECIMALS = 18;

    uint256 public constant ONE = 1e18;

    bytes public constant ZERO_BYTES = new bytes(0);

    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
}