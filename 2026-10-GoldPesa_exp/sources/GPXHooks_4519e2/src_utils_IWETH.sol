// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IWETH
 * @notice Interface for the Wrapped Ether (WETH) contract.
 *
 * @dev WETH is an ERC20-compliant token that wraps native ETH.
 * - It allows ETH to be used in ERC20-based protocols by enabling deposit and withdrawal of native ETH in exchange for WETH tokens.
 *
 */
interface IWETH {
    /**
     * @notice Emitted when ETH is deposited and WETH is minted to the user.
     * @param dst The address receiving the WETH tokens.
     * @param wad The amount of ETH deposited (and WETH minted).
     */
    event Deposit(address indexed dst, uint256 wad);

    /**
     * @notice Emitted when WETH is burned and ETH is returned to the user.
     * @param src The address redeeming WETH for ETH.
     * @param wad The amount of WETH burned (and ETH withdrawn).
     */
    event Withdrawal(address indexed src, uint256 wad);

    /**
     * @notice Deposit native ETH into the contract and receive an equivalent amount of WETH.
     * @dev The caller must send ETH along with the transaction. Emits a {Deposit} event.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw native ETH by burning the corresponding amount of WETH.
     * @param wad The amount of WETH to convert back into ETH.
     * @dev Emits a {Withdrawal} event. Reverts if caller has insufficient WETH balance.
     */
    function withdraw(uint256 wad) external;

    /**
     * @notice Returns the WETH balance of the given account.
     * @param account The address to query.
     * @return uint256 The WETH token balance of the account.
     */
    function balanceOf(address account) external view returns (uint256);
}

