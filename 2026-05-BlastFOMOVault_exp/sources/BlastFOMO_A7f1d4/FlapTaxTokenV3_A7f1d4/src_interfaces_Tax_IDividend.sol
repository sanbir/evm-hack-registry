// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Interface for the Dividend distribution contract
interface IDividend {
    // --- Events ---
    /// @notice Emitted when a user's share is updated
    /// @param taxToken The tax token contract address
    /// @param user The user whose share was changed
    /// @param newShare The new share amount for the user
    /// @param totalShares The total shares after the change
    event FlapDividendShareChanged(
        address indexed taxToken, address indexed user, uint256 newShare, uint256 totalShares
    );

    /// @notice Emitted when dividends are deposited into the contract
    /// @param taxToken The tax token contract address
    /// @param amount The amount of dividend tokens deposited
    /// @param magnifiedDividendPerShare The updated magnified dividend per share
    event FlapDividendDeposited(address indexed taxToken, uint256 amount, uint256 magnifiedDividendPerShare);

    /// @notice Emitted when dividends are distributed to a user
    /// @param taxToken The tax token contract address
    /// @param user The user who received the dividends
    /// @param amount The amount of dividends distributed
    event FlapDividendDistributed(address indexed taxToken, address user, uint256 amount);

    /// @notice Emitted when an address is excluded from receiving dividends
    /// @param taxToken The tax token contract address
    /// @param addr The address that was excluded
    event FlapDividendAddressExcluded(address indexed taxToken, address addr);

    /// @notice Emitted when a dividend withdrawal fails
    /// @param taxToken The tax token contract address
    /// @param user The user for whom the withdrawal failed
    /// @param amount The amount that failed to be withdrawn
    event FlapDividendWithdrawalFailed(address indexed taxToken, address user, uint256 amount);

    /// @notice Emitted when a user's pending balance changes
    /// @param taxToken The tax token contract address
    /// @param user The user whose pending balance changed
    /// @param pendingBalance The new pending balance
    event FlapDividendPendingBalanceChanged(address indexed taxToken, address indexed user, uint256 pendingBalance);

    /// @notice Emitted when a user's reward debt changes
    /// @param taxToken The tax token contract address
    /// @param user The user whose reward debt changed
    /// @param rewardDebt The new reward debt
    event FlapDividendRewardDebtChanged(address indexed taxToken, address indexed user, uint256 rewardDebt);

    /// @notice Initialize the dividend contract
    /// @param dividendToken_ The token used for dividend payments
    /// @param taxToken_ The tax token contract address
    /// @param minimumShareBalance_ The minimum balance required for dividend eligibility
    function initialize(address dividendToken_, address taxToken_, uint256 minimumShareBalance_) external;

    /// @notice Set user's share (only callable by FlapTaxToken)
    /// @param user The user address
    /// @param share The new share amount for the user
    function setShare(address user, uint256 share) external;

    /// @notice Deposit dividends to be distributed
    /// @param amount The amount of dividend tokens to deposit
    /// @return success Whether the deposit was successful
    function deposit(uint256 amount) external returns (bool success);

    /// @notice Batch distribute dividends to specified users
    /// @param users Array of user addresses to distribute dividends to
    /// @return successCount Number of successful distributions
    function distributeDividend(address[] calldata users) external returns (uint256 successCount);

    /// @notice User can call this to withdraw their own dividends (unwraps WETH to ETH if applicable)
    /// @return success Whether the withdrawal was successful
    function withdrawDividends() external returns (bool success);

    /// @notice Withdraw dividends for a specific user
    /// @param user The user address to withdraw for
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user) external returns (bool success);

    /// @notice Withdraw dividends for a specific user with option to unwrap WETH
    /// @param user The user address to withdraw for
    /// @param unwrapWETH Whether to unwrap WETH to ETH
    /// @return success Whether the withdrawal was successful
    function withdrawDividendsFor(address user, bool unwrapWETH) external returns (bool success);

    /// @notice Get the withdrawable dividend amount for a user
    /// @param user The user address
    /// @return The amount of dividends the user can claim
    function withdrawableDividends(address user) external view returns (uint256);

    /// @notice Exclude an address from receiving dividends
    /// @param addr The address to exclude
    function excludeAddress(address addr) external;

    /// @notice Get total shares across all users
    /// @return The total amount of shares
    function totalShares() external view returns (uint256);

    /// @notice Get the minimum share balance required for dividend eligibility
    /// @return The minimum share balance
    function minimumShareBalance() external view returns (uint256);

    /// @notice Get total dividends withdrawn by a user
    /// @param user The user address
    /// @return The total amount of dividends withdrawn
    function withdrawnDividends(address user) external view returns (uint256);

    /// @notice Emergency withdraw function to recover tokens in case of emergency
    /// @param token The token address to withdraw (use address(0) for native ETH)
    /// @param amount The amount to withdraw (0 means withdraw all)
    /// @param to The address to send the tokens to
    function emergencyWithdraw(address token, uint256 amount, address to) external;
}
