// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title IAugustusFeeVault
/// @notice Interface for the AugustusFeeVault contract
interface IAugustusFeeVault {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error emitted when withdraw amount is zero or exceeds the stored amount
    error InvalidWithdrawAmount();

    /// @notice Error emmitted when caller is not an approved augustus contract
    error UnauthorizedCaller();

    /// @notice Error emitted when an invalid parameter length is passed
    error InvalidParameterLength();

    /// @notice Error emitted when batch withdraw fails
    error BatchCollectFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an augustus contract approval status is set
    /// @param augustus The augustus contract address
    /// @param approved The approval status
    event AugustusApprovalSet(address indexed augustus, bool approved);

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows partners to withdraw fees allocated to them and stored in the vault
    /// @param token The token to withdraw fees in
    /// @param amount The amount of fees to withdraw
    /// @param recipient The address to send the fees to
    /// @return success Whether the transfer was successful or not
    function withdrawSomeERC20(IERC20 token, uint256 amount, address recipient) external returns (bool success);

    /// @notice Allows partners to withdraw all fees allocated to them and stored in the vault for a given token
    /// @param token The token to withdraw fees in
    /// @param recipient The address to send the fees to
    /// @return success Whether the transfer was successful or not
    function withdrawAllERC20(IERC20 token, address recipient) external returns (bool success);

    /// @notice Allows partners to withdraw all fees allocated to them and stored in the vault for multiple tokens
    /// @param tokens The tokens to withdraw fees i
    /// @param recipient The address to send the fees to
    /// @return success Whether the transfer was successful or not
    function batchWithdrawAllERC20(IERC20[] calldata tokens, address recipient) external returns (bool success);

    /// @notice Allows partners to withdraw fees allocated to them and stored in the vault
    /// @param tokens The tokens to withdraw fees in
    /// @param amounts The amounts of fees to withdraw
    /// @param recipient The address to send the fees to
    /// @return success Whether the transfer was successful or not
    function batchWithdrawSomeERC20(
        IERC20[] calldata tokens,
        uint256[] calldata amounts,
        address recipient
    )
        external
        returns (bool success);

    /*//////////////////////////////////////////////////////////////
                            BALANCE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the balance of a given token for a given partner
    /// @param token The token to get the balance of
    /// @param partner The partner to get the balance for
    /// @return feeBalance The balance of the given token for the given partner
    function getBalance(IERC20 token, address partner) external view returns (uint256 feeBalance);

    /// @notice Get the balances of a given partner for multiple tokens
    /// @param tokens The tokens to get the balances of
    /// @param partner The partner to get the balances for
    /// @return feeBalances The balances of the given tokens for the given partner
    function batchGetBalance(
        IERC20[] calldata tokens,
        address partner
    )
        external
        view
        returns (uint256[] memory feeBalances);

    /// @notice Returns the unallocated fees for a given token
    /// @param token The token to get the unallocated fees for
    /// @return unallocatedFees The unallocated fees for the given token
    function getUnallocatedFees(IERC20 token) external view returns (uint256 unallocatedFees);

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Register fees for a given account and token, only callable by approved augustus contracts
    /// @param account The account to register the fees for
    /// @param token The token to register the fees for
    /// @param fee The amount of fees to register
    function registerFee(address account, IERC20 token, uint256 fee) external;

    /// @notice Sets the augustus contract approval status
    /// @param augustus The augustus contract address
    /// @param approved The approval status
    function setAugustusApproval(address augustus, bool approved) external;
}
