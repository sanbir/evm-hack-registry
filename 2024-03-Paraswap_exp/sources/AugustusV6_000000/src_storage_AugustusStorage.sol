// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

// @title AugustusStorage
// @notice Inherited storage layout for AugustusV6,
// contracts should inherit this contract to access the storage layout
contract AugustusStorage {
    /*//////////////////////////////////////////////////////////////
                               FEES
    //////////////////////////////////////////////////////////////*/

    // @dev Mapping of tokens to boolean indicating if token is blacklisted for fee collection
    mapping(IERC20 token => bool isBlacklisted) public blacklistedTokens;

    // @dev Fee wallet to directly transfer paraswap share to
    address payable public feeWallet;

    // @dev Fee wallet address to register the paraswap share to in the fee vault
    address payable public feeWalletDelegate;
}
