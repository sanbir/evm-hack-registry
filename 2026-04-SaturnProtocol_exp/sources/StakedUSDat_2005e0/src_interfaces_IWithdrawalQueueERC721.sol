// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IWithdrawalQueueERC721
 * @author Saturn
 * @notice Interface for the WithdrawalQueueERC721 contract.
 * @dev A UUPS upgradeable NFT-based withdrawal queue where each withdrawal request
 * is represented as an ERC721 token. Users request redemptions from StakedUSDat,
 * their shares are escrowed, and they receive an NFT representing their claim.
 * Processors then sell STRC off-chain, and users can claim their USDat once processed.
 */
interface IWithdrawalQueueERC721 {
    // ============ Enums ============

    /**
     * @notice The lifecycle status of a withdrawal request.
     */
    enum RequestStatus {
        NULL,
        Requested,
        InProgress,
        Processed,
        Claimed
    }

    // ============ Structs ============

    /**
     * @notice Withdrawal request data structure.
     * @param shares The number of sUSDat shares escrowed.
     * @param usdatOwed The amount of USDat owed after processing.
     * @param timestamp The timestamp when the request was created.
     * @param minUsdatReceived The minimum USDat the user will accept (slippage protection).
     * @param status The current status of the request.
     */
    struct Request {
        uint256 shares;
        uint256 usdatOwed;
        uint256 timestamp;
        uint256 minUsdatReceived;
        RequestStatus status;
    }

    // ============ Errors ============

    /**
     * @dev Thrown when a zero amount is provided where a non-zero value is required.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when attempting to process a request that has already been processed.
     */
    error AlreadyProcessed();

    /**
     * @dev Thrown when there are no claimable requests for the user.
     */
    error NothingToClaim();

    /**
     * @dev Thrown when the caller is not the owner of the token.
     */
    error NotOwner();

    /**
     * @dev Thrown when an operation requires a blacklisted address but the address is not blacklisted.
     */
    error NotBlacklisted();

    /**
     * @dev Thrown when invalid inputs are provided.
     */
    error InvalidInputs();

    /**
     * @dev Thrown when the execution price doesn't match expected within tolerance.
     */
    error ExecutionPriceMismatch();

    /**
     * @dev Thrown when the execution price doesn't match the oracle price within tolerance.
     */
    error OraclePriceMismatch();

    /**
     * @dev Thrown when attempting to claim a request that hasn't been processed yet.
     */
    error RequestNotProcessed();

    /**
     * @dev Thrown when an operation involves a blacklisted address.
     */
    error AddressBlacklisted();

    /**
     * @dev Thrown when slippage protection is triggered (received less than minimum).
     */
    error SlippageExceeded();

    /**
     * @dev Thrown when attempting to sell more STRC than the vested balance.
     */
    error ExceedsVestedBalance();

    /**
     * @dev Thrown when attempting to process a request that is not locked.
     */
    error RequestNotLocked();

    // ============ Events ============

    /**
     * @dev Emitted when a new withdrawal request is created.
     * @param tokenId The NFT token ID representing the request.
     * @param user The user who created the request.
     * @param shares The number of shares escrowed.
     * @param timestamp The timestamp of the request.
     */
    event WithdrawalRequested(uint256 indexed tokenId, address indexed user, uint256 shares, uint256 timestamp);

    /**
     * @dev Emitted when requests are locked for processing.
     * @param tokenIds The array of token IDs that were locked.
     */
    event RequestsLocked(uint256[] tokenIds);

    /**
     * @dev Emitted when requests are unlocked after a failed processing attempt.
     * @param tokenIds The array of token IDs that were unlocked.
     */
    event RequestsUnlocked(uint256[] tokenIds);

    /**
     * @dev Emitted when a withdrawal request is processed.
     * @param tokenId The NFT token ID of the processed request.
     * @param shares The number of shares that were redeemed.
     * @param usdatAmount The amount of USDat allocated to the user.
     */
    event WithdrawalProcessed(uint256 indexed tokenId, uint256 shares, uint256 usdatAmount);

    /**
     * @dev Emitted when a user claims their USDat.
     * @param tokenId The NFT token ID that was claimed.
     * @param user The user who claimed.
     * @param usdatAmount The amount of USDat claimed.
     */
    event Claimed(uint256 indexed tokenId, address indexed user, uint256 usdatAmount);

    /**
     * @dev Emitted when processed funds are seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The blacklisted user whose funds were seized.
     * @param usdatAmount The amount of USDat seized.
     * @param to The address that received the seized funds.
     */
    event FundsSeized(uint256 indexed tokenId, address indexed user, uint256 usdatAmount, address indexed to);

    /**
     * @dev Emitted when a pending request is seized from a blacklisted user.
     * @param tokenId The NFT token ID of the seized request.
     * @param user The blacklisted user whose request was seized.
     * @param to The address that received the NFT.
     */
    event RequestSeized(uint256 indexed tokenId, address indexed user, address indexed to);

    /**
     * @dev Emitted when a user updates their minimum USDat amount.
     * @param tokenId The NFT token ID of the updated request.
     * @param newMinUsdatReceived The new minimum USDat amount.
     */
    event MinUsdatReceivedUpdated(uint256 indexed tokenId, uint256 newMinUsdatReceived);

    // ============ Admin Functions ============

    /**
     * @notice Pauses the contract.
     * @dev Only callable by addresses with the COMPLIANCE_ROLE.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    // ============ Request Creation ============

    /**
     * @notice Creates a new withdrawal request.
     * @dev Called by StakedUSDat when a user requests redemption.
     * Mints an NFT to the user representing their withdrawal request.
     * Only callable by addresses with the STAKED_USDAT_ROLE.
     * @param user The user requesting withdrawal.
     * @param shares The amount of sUSDat shares escrowed.
     * @param minUsdatReceived The minimum amount of USDat the user will accept.
     * @return tokenId The NFT token ID (same as request ID).
     */
    function addRequest(address user, uint256 shares, uint256 minUsdatReceived) external returns (uint256 tokenId);

    /**
     * @notice Updates the minimum USDat amount for a pending withdrawal request.
     * @dev Can only be called by the NFT owner. For InProgress requests, can only lower
     * the minimum (more lenient slippage). For Requested status, can adjust in any direction.
     * @param tokenId The token ID of the request to update.
     * @param newMinUsdatReceived The new minimum USDat amount.
     */
    function updateMinUsdatReceived(uint256 tokenId, uint256 newMinUsdatReceived) external;

    // ============ Processing Functions ============

    /**
     * @notice Locks requests for processing.
     * @dev Prevents user modifications while requests are being processed off-chain.
     * Only callable by addresses with the PROCESSOR_ROLE.
     * @param tokenIds Array of token IDs to lock.
     */
    function lockRequests(uint256[] calldata tokenIds) external;

    /**
     * @notice Unlocks requests if processing fails.
     * @dev Returns requests to the Requested state so users can modify them.
     * Only callable by addresses with the PROCESSOR_ROLE.
     * @param tokenIds Array of token IDs to unlock.
     */
    function unlockRequests(uint256[] calldata tokenIds) external;

    /**
     * @notice Processes a batch of withdrawal requests.
     * @dev Validates the execution against oracle prices and allocates USDat pro-rata.
     * Burns the escrowed shares and decreases strcBalance, then transfers USDat for users to claim.
     * Only callable by addresses with the PROCESSOR_ROLE.
     * @param tokenIds Array of token IDs to process.
     * @param totalUsdatReceived Amount of USDat received from selling STRC off-chain.
     * @param totalStrcSold Amount of STRC that was sold off-chain.
     * @param executionPrice The price per STRC in USDat terms (8 decimals) for validation.
     */
    function processRequests(
        uint256[] calldata tokenIds,
        uint256 totalUsdatReceived,
        uint256 totalStrcSold,
        uint256 executionPrice
    ) external;

    // ============ Claiming Functions ============

    /**
     * @notice Claims a specific withdrawal request by token ID.
     * @dev Burns the NFT and transfers USDat to the caller.
     * @param tokenId The NFT token ID to claim.
     * @return amount The amount of USDat claimed.
     */
    function claim(uint256 tokenId) external returns (uint256 amount);

    /**
     * @notice Claims multiple withdrawal requests.
     * @dev Burns the NFTs and transfers total USDat to the caller.
     * @param tokenIds Array of token IDs to claim.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount);

    /**
     * @notice Claims specific withdrawal requests for a user.
     * @dev Called by StakedUSDat on behalf of the user.
     * Only callable by addresses with the STAKED_USDAT_ROLE.
     * @param user The user who owns the NFTs and will receive the USDat.
     * @param tokenIds Array of token IDs to claim.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claimBatchFor(address user, uint256[] calldata tokenIds) external returns (uint256 totalAmount);

    /**
     * @notice Claims all processed withdrawals for the caller.
     * @dev Iterates through all NFTs owned by caller. Gas cost scales with ownership count.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claimAll() external returns (uint256 totalAmount);

    /**
     * @notice Claims all processed withdrawals for a user.
     * @dev Called by StakedUSDat on behalf of the user.
     * Only callable by addresses with the STAKED_USDAT_ROLE.
     * @param user The user to claim for.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claimAllFor(address user) external returns (uint256 totalAmount);

    // ============ View Functions ============

    /**
     * @notice Gets all token IDs owned by the caller.
     * @return tokenIds Array of token IDs owned by the caller.
     */
    function getMyRequests() external view returns (uint256[] memory tokenIds);

    /**
     * @notice Gets all token IDs owned by a user.
     * @param user The user to query.
     * @return tokenIds Array of token IDs owned by the user.
     */
    function getUserRequests(address user) external view returns (uint256[] memory tokenIds);

    /**
     * @notice Gets claimable amount and token IDs for a user.
     * @param user The user to query.
     * @return total The total claimable USDat amount.
     * @return claimableIds Array of claimable token IDs.
     */
    function getClaimable(address user) external view returns (uint256 total, uint256[] memory claimableIds);

    /**
     * @notice Gets pending (unprocessed) requests for a user.
     * @param user The user to query.
     * @return totalShares The total shares in pending requests.
     * @return pendingIds Array of pending token IDs.
     */
    function getPending(address user) external view returns (uint256 totalShares, uint256[] memory pendingIds);

    /**
     * @notice Gets a specific request's details.
     * @param tokenId The token ID to query.
     * @return The request data.
     */
    function getRequest(uint256 tokenId) external view returns (Request memory);

    /**
     * @notice Gets the status of a specific request.
     * @param tokenId The token ID to check.
     * @return The current status of the request.
     */
    function getStatus(uint256 tokenId) external view returns (RequestStatus);

    /**
     * @notice Checks if a specific request is claimable.
     * @dev Returns false if token doesn't exist (was already claimed/burned).
     * @param tokenId The token ID to check.
     * @return True if the request is claimable.
     */
    function isClaimable(uint256 tokenId) external view returns (bool);

    /**
     * @notice Gets the number of pending requests in the queue.
     * @return The pending request count.
     */
    function getPendingCount() external view returns (uint256);

    /**
     * @notice Gets total sUSDat shares waiting to be processed.
     * @return The total pending shares.
     */
    function getTotalPendingShares() external view returns (uint256);

    /**
     * @notice Gets the total number of requests ever made.
     * @return The total request count.
     */
    function getTotalRequests() external view returns (uint256);

    /**
     * @notice Gets pending request IDs within a range.
     * @param start Starting tokenId (inclusive).
     * @param end Ending tokenId (exclusive).
     * @return pendingIds Array of pending tokenIds in the range.
     */
    function getPendingIdsInRange(uint256 start, uint256 end) external view returns (uint256[] memory pendingIds);

    // ============ Compliance Functions ============

    /**
     * @notice Seizes pending requests from blacklisted holders.
     * @dev Transfers NFTs from blacklisted users to the specified address.
     * Only works for Requested and InProgress status.
     * Only callable by addresses with the COMPLIANCE_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the NFTs to.
     */
    function seizeRequests(uint256[] calldata tokenIds, address to) external;

    /**
     * @notice Seizes processed requests from blacklisted holders.
     * @dev Burns NFTs and transfers USDat to the specified address.
     * Only works for Processed status.
     * Only callable by addresses with the COMPLIANCE_ROLE.
     * @param tokenIds Array of token IDs to seize.
     * @param to The address to transfer the USDat to.
     */
    function seizeBlacklistedFunds(uint256[] calldata tokenIds, address to) external;
}
