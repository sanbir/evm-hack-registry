// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @notice An interface for the Wrapped Ether (WETH) token, which is a key component for
 * enabling Ether to be used within decentralized applications that require the ERC-20 standard.
 * It allows for the seamless wrapping of native Ether into an ERC-20 compliant token and vice versa.
 */
interface IWETH is IERC20 {
    /**
     * @notice Deposits native Ether to receive an equivalent amount of WETH tokens.
     * @dev The WETH tokens are minted and sent to the address that called this function.
     * This is a payable function, allowing it to receive and convert the native Ether.
     */
    function deposit() external payable;

    /**
     * @notice Burns WETH tokens to withdraw an equivalent amount of native Ether.
     * @dev The specified amount of WETH is burned from the caller's balance, and the corresponding
     * Ether is sent back to their address.
     * @param amount The quantity of WETH tokens to burn and convert back to Ether.
     */
    function withdraw(uint256 amount) external;
}
