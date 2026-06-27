// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IStakedUSDat
 * @author Saturn
 * @notice Interface for the StakedUSDat (sUSDat) ERC4626 vault contract.
 * @dev StakedUSDat is a UUPS upgradeable ERC4626 vault for staking USDat.
 * Users deposit USDat and receive sUSDat shares representing their stake.
 * The vault holds both USDat and tracks STRC holdings internally via strcBalance.
 * STRC holdings are managed by the Saturn entity. Rewards are distributed as STRC
 * and vest linearly over a configurable period to prevent front-running attacks.
 */
interface IStakedUSDat is IERC4626 {
    // ============ Errors ============

    /**
     * @dev Thrown when a zero address is provided where a valid address is required.
     */
    error InvalidZeroAddress();

    /**
     * @dev Thrown when an operation involves a zero amount where a non-zero value is required.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when an operation is not allowed (e.g., direct withdraw/redeem).
     */
    error OperationNotAllowed();

    /**
     * @dev Thrown when attempting to un-blacklist an address that is not blacklisted.
     */
    error AddressNotBlacklisted();

    /**
     * @dev Thrown when an operation involves a blacklisted address.
     */
    error AddressBlacklisted();

    /**
     * @dev Thrown when attempting to redistribute locked amounts with no valid recipients.
     */
    error NoRecipientsForRedistribution();

    /**
     * @dev Thrown when attempting to blacklist an admin address.
     */
    error CannotBlacklistAdmin();

    /**
     * @dev Thrown when an operation requires more balance than available.
     */
    error InsufficientBalance();

    /**
     * @dev Thrown when attempting to change vesting period or add rewards while rewards are still vesting.
     */
    error StillVesting();

    /**
     * @dev Thrown when an invalid vesting period is provided.
     */
    error InvalidVestingPeriod();

    /**
     * @dev Thrown when a withdrawal amount is below the minimum threshold.
     */
    error WithdrawalTooSmall();

    /**
     * @dev Thrown when slippage protection is triggered (received less than minimum).
     */
    error SlippageExceeded();

    /**
     * @dev Thrown when the execution price doesn't match expected within tolerance.
     */
    error ExecutionPriceMismatch();

    /**
     * @dev Thrown when the execution price doesn't match the oracle price within tolerance.
     */
    error OraclePriceMismatch();

    /**
     * @dev Thrown when an invalid fee value is provided.
     */
    error InvalidFee();

    /**
     * @dev Thrown when rewards exceed the maximum allowed percentage of totalAssets.
     */
    error RewardsExceedMax();

    // ============ Events ============

    /**
     * @dev Emitted when an address is added to the blacklist.
     * @param target The address that was blacklisted.
     */
    event Blacklisted(address indexed target);

    /**
     * @dev Emitted when an address is removed from the blacklist.
     * @param target The address that was un-blacklisted.
     */
    event UnBlacklisted(address indexed target);

    /**
     * @dev Emitted when USDat is converted to/from tSTRC.
     * @param usdatAmount The amount of USDat involved in the conversion.
     * @param strcAmount The amount of tSTRC involved in the conversion.
     */
    event Converted(uint256 usdatAmount, uint256 strcAmount);

    /**
     * @dev Emitted when rewards are transferred into the contract.
     * @param amount The amount of tSTRC rewards received.
     * @param newVestingAmount The total amount now vesting.
     */
    event RewardsReceived(uint256 amount, uint256 newVestingAmount);

    /**
     * @dev Emitted when locked amounts are redistributed from a blacklisted address.
     * @param from The blacklisted address whose funds were redistributed.
     * @param amount The amount of shares that were burned.
     */
    event LockedAmountRedistributed(address indexed from, uint256 amount);

    /**
     * @dev Emitted when the vesting period is updated.
     * @param oldPeriod The previous vesting period in seconds.
     * @param newPeriod The new vesting period in seconds.
     */
    event VestingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    /**
     * @dev Emitted when the deposit fee is updated.
     * @param newFee The new deposit fee in basis points.
     */
    event DepositFeeUpdated(uint256 newFee);

    /**
     * @dev Emitted when the fee recipient is updated.
     * @param newRecipient The new fee recipient address.
     */
    event FeeRecipientUpdated(address indexed newRecipient);

    /**
     * @dev Emitted when the price tolerance is updated.
     * @param newToleranceBps The new tolerance in basis points.
     */
    event ToleranceUpdated(uint256 newToleranceBps);

    /**
     * @dev Emitted when the max rewards basis points is updated.
     * @param newMaxBps The new max rewards in basis points.
     */
    event MaxRewardsBpsUpdated(uint256 newMaxBps);

    // ============ Blacklist Functions ============

    /**
     * @notice Adds an address to the blacklist.
     * @dev Only callable by addresses with the COMPLIANCE_ROLE.
     * Cannot blacklist addresses with DEFAULT_ADMIN_ROLE.
     * @param target The address to blacklist.
     */
    function addToBlacklist(address target) external;

    /**
     * @notice Removes an address from the blacklist.
     * @dev Only callable by addresses with the COMPLIANCE_ROLE.
     * @param target The address to un-blacklist.
     */
    function removeFromBlacklist(address target) external;

    /**
     * @notice Checks if an address is blacklisted.
     * @param account The address to check.
     * @return True if the address is blacklisted, false otherwise.
     */
    function isBlacklisted(address account) external view returns (bool);

    /**
     * @notice Burns shares from a blacklisted address, redistributing value to other holders.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * The target address must be blacklisted and have a positive balance.
     * @param from The blacklisted address to redistribute from.
     */
    function redistributeLockedAmount(address from) external;

    // ============ Asset Management Functions ============

    /**
     * @notice Rescues tokens accidentally sent to the contract.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * For USDat, only allows rescuing amounts above the internally tracked balance.
     * @param token The address of the token to rescue.
     * @param amount The amount of tokens to rescue.
     * @param to The address to send the rescued tokens to.
     */
    function rescueTokens(address token, uint256 amount, address to) external;

    /**
     * @notice Converts USDat to STRC when the entity purchases STRC from the market.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Decreases usdatBalance and increases strcBalance based on the purchase price.
     * @param usdatAmount The amount of USDat to convert.
     * @param strcAmount The amount of STRC to add.
     * @param strcPurchasePrice The price per STRC in USDat terms (8 decimals).
     */
    function convertFromUsdat(uint256 usdatAmount, uint256 strcAmount, uint256 strcPurchasePrice) external;

    /**
     * @notice Converts STRC to USDat when the entity sells STRC to the market.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Decreases strcBalance and increases usdatBalance based on the sale price.
     * Can only convert vested STRC (unvested rewards are protected).
     * @param strcAmount The amount of STRC to remove.
     * @param usdatAmount The amount of USDat to add.
     * @param strcSalePrice The price per STRC in USDat terms (8 decimals).
     */
    function convertFromStrc(uint256 strcAmount, uint256 usdatAmount, uint256 strcSalePrice) external;

    /**
     * @notice Transfers STRC rewards into the contract with linear vesting.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Cannot be called while previous rewards are still vesting.
     * Rewards vest linearly over the vestingPeriod to prevent front-running.
     * @param amount The amount of STRC to add as rewards.
     */
    function transferInRewards(uint256 amount) external;

    // ============ Deposit Functions ============

    /**
     * @notice Deposits assets with slippage protection.
     * @dev Reverts if the shares received would be less than minShares.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive.
     * @return shares The number of shares minted.
     */
    function depositWithMinShares(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

    /**
     * @notice Mints shares with slippage protection.
     * @dev Reverts if the assets required would exceed maxAssets.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend.
     * @return assets The amount of assets spent.
     */
    function mintWithMaxAssets(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets);

    /**
     * @notice Deposits assets with EIP-2612 permit for gasless approval.
     * @dev Combines permit and deposit in a single transaction.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive (slippage protection).
     * @param deadline The permit signature deadline.
     * @param v The permit signature v component.
     * @param r The permit signature r component.
     * @param s The permit signature s component.
     * @return shares The number of shares minted.
     */
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares with EIP-2612 permit for gasless approval.
     * @dev Combines permit and mint in a single transaction.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend (slippage protection).
     * @param deadline The permit signature deadline.
     * @param v The permit signature v component.
     * @param r The permit signature r component.
     * @param s The permit signature s component.
     * @return assets The amount of assets spent.
     */
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 assets);

    /**
     * @notice Deposits assets with EIP-1271 permit for smart contract wallet approval.
     * @dev Combines permit and deposit in a single transaction. Supports smart contract
     * wallets like Gnosis Safe, Argent, etc. that implement EIP-1271.
     * @param assets The amount of assets to deposit.
     * @param receiver The address to receive the shares.
     * @param minShares The minimum number of shares to receive (slippage protection).
     * @param deadline The permit signature deadline.
     * @param signature The EIP-1271 compatible signature bytes.
     * @return shares The number of shares minted.
     */
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 minShares,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 shares);

    /**
     * @notice Mints shares with EIP-1271 permit for smart contract wallet approval.
     * @dev Combines permit and mint in a single transaction. Supports smart contract
     * wallets like Gnosis Safe, Argent, etc. that implement EIP-1271.
     * @param shares The number of shares to mint.
     * @param receiver The address to receive the shares.
     * @param maxAssets The maximum amount of assets to spend (slippage protection).
     * @param deadline The permit signature deadline.
     * @param signature The EIP-1271 compatible signature bytes.
     * @return assets The amount of assets spent.
     */
    function mintWithPermit(
        uint256 shares,
        address receiver,
        uint256 maxAssets,
        uint256 deadline,
        bytes memory signature
    ) external returns (uint256 assets);

    // ============ Withdrawal Functions ============

    /**
     * @notice Requests a redemption by escrowing shares in the withdrawal queue.
     * @dev Standard ERC4626 withdraw/redeem are disabled. Use this function instead.
     * Transfers shares to the withdrawal queue and mints an NFT representing the request.
     * @param shares The number of shares to redeem.
     * @param minUsdatReceived The minimum amount of USDat the user will accept.
     * @return requestId The ID of the withdrawal request NFT.
     */
    function requestRedeem(uint256 shares, uint256 minUsdatReceived) external returns (uint256 requestId);

    /**
     * @notice Claims all processed withdrawals for the caller.
     * @dev Delegates to the withdrawal queue to process claims.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claim() external returns (uint256 totalAmount);

    /**
     * @notice Claims specific withdrawal requests for the caller.
     * @dev Delegates to the withdrawal queue to process claims.
     * @param tokenIds Array of withdrawal request NFT token IDs to claim.
     * @return totalAmount The total amount of USDat claimed.
     */
    function claimBatch(uint256[] calldata tokenIds) external returns (uint256 totalAmount);

    /**
     * @notice Burns escrowed shares and decreases strcBalance for the STRC sold off-chain.
     * @dev Only callable by the withdrawal queue during processing.
     * @param shares The number of shares to burn.
     * @param strcAmount The amount of STRC that was sold off-chain.
     */
    function burnQueuedShares(uint256 shares, uint256 strcAmount) external;

    /**
     * @notice Collects dust from withdrawal queue processing.
     * @dev Only callable by the withdrawal queue. Pulls USDat dust and
     * adds it to the internal accounting balance.
     * @param amount The amount of USDat dust to collect.
     */
    function collectDust(uint256 amount) external;

    // ============ View Functions ============

    /**
     * @notice Returns the amount of STRC that is still vesting.
     * @dev Rounds up to be conservative (slightly favors protocol over users).
     * @return The unvested STRC amount.
     */
    function getUnvestedAmount() external view returns (uint256);

    /**
     * @notice Returns the withdrawal queue contract address.
     * @return The address of the WithdrawalQueueERC721 contract.
     */
    function getWithdrawalQueue() external view returns (address);

    /**
     * @notice Returns the STRC price oracle contract address.
     * @return The address of the StrcPriceOracle contract.
     */
    function getStrcOracle() external view returns (address);

    /**
     * @notice Returns the current tolerance in basis points for conversion validation.
     * @return The tolerance value in basis points.
     */
    function toleranceBps() external view returns (uint256);

    /**
     * @notice Returns the internally tracked STRC balance.
     * @return The STRC balance.
     */
    function strcBalance() external view returns (uint256);

    /**
     * @notice Returns the current amount of STRC vesting.
     * @return The vesting amount.
     */
    function vestingAmount() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the last reward distribution.
     * @return The Unix timestamp.
     */
    function lastDistributionTimestamp() external view returns (uint256);

    /**
     * @notice Returns the current vesting period duration.
     * @return The vesting period in seconds.
     */
    function vestingPeriod() external view returns (uint256);

    /**
     * @notice Returns the current deposit fee in basis points.
     * @return The fee in basis points.
     */
    function depositFeeBps() external view returns (uint256);

    /**
     * @notice Returns the current fee recipient address.
     * @return The fee recipient address.
     */
    function feeRecipient() external view returns (address);

    /**
     * @notice Returns the internally tracked USDat balance.
     * @return The USDat balance.
     */
    function usdatBalance() external view returns (uint256);

    /**
     * @notice Returns the maximum rewards per transfer in basis points of totalAssets.
     * @return The max rewards basis points.
     */
    function maxRewardsBps() external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Updates the vesting period for reward distributions.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Cannot be changed while rewards are still vesting.
     * @param newVestingPeriod The new vesting period in seconds (must be <= MAX_VESTING_PERIOD).
     */
    function setVestingPeriod(uint256 newVestingPeriod) external;

    /**
     * @notice Updates the deposit fee.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Can be set to 0 to disable fees.
     * @param newFeeBps The new fee in basis points (must be <= MAX_DEPOSIT_FEE_BPS).
     */
    function setDepositFee(uint256 newFeeBps) external;

    /**
     * @notice Updates the fee recipient address.
     * @dev Only callable by addresses with the PROCESSOR_ROLE.
     * Can be set to address(0) to disable fees.
     * @param newRecipient The new fee recipient address.
     */
    function setFeeRecipient(address newRecipient) external;

    /**
     * @notice Updates the price tolerance for conversion validation.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * Use during black swan events when market prices deviate significantly.
     * @param newToleranceBps The new tolerance in basis points (MIN_TOLERANCE_BPS to MAX_TOLERANCE_BPS).
     */
    function setTolerance(uint256 newToleranceBps) external;

    /**
     * @notice Updates the maximum rewards per transfer as a percentage of totalAssets.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * @param newMaxBps The new maximum in basis points (e.g., 250 = 2.5%).
     */
    function setMaxRewardsBps(uint256 newMaxBps) external;

    /**
     * @notice Pauses the contract.
     * @dev Only callable by addresses with the COMPLIANCE_ROLE.
     * When paused, deposits, mints, and redemption requests are disabled.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;
}
