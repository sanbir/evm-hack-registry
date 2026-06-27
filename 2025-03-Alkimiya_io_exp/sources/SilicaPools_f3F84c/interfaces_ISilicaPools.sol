///// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 *      _    _ _    _           _
 *     / \  | | | _(_)_ __ ___ (_)_   _  __ _
 *    / _ \ | | |/ / | '_ ` _ \| | | | |/ _` |
 *   / ___ \| |   <| | | | | | | | |_| | (_| |
 *  /_/__ \_\_|_|\_\_|_| |_| |_|_|\__, |\__,_|_
 *  / ___|(_) (_) ___ __ _  |  _ \|___/  ___ | |___
 *  \___ \| | | |/ __/ _` | | |_) / _ \ / _ \| / __|
 *   ___) | | | | (_| (_| | |  __/ (_) | (_) | \__ \
 *  |____/|_|_|_|\___\__,_| |_|   \___/ \___/|_|___/
 */
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/token/ERC1155/IERC1155.sol";

import {ISilicaIndex} from "./ISilicaIndex.sol";

/// @title Silica Pools Protocol
/// @author Alkimiya
/// @notice Protocol for allocating tokens into pools which track
///         a balance change over a specified period and pay out
///         accordingly: https://www.investopedia.com/terms/v/verticalspread.asp
/// @custom:example If a pool specifies strikes of 100-200 DAI per share
///                 over a 1 year term, and the balance change over the term
///                 is 160 DAI per share, then at the end of the pool's term,
///                 60 DAI per share (160 - 100) is paid out to
///                 holders of long shares, and 40 DAI per share (200 - 160)
///                 is paid out to holders of short shares.
interface ISilicaPools is IERC1155 {
    event SilicaPools__FillFeeChanged(uint256 newFeeBps);
    event SilicaPools__GracePeriodChanged(uint256 newGracePeriod);
    event SilicaPools__BountyIncreaseRateChanged(uint256 newRate);
    event SilicaPools__MaxBountyFractionChanged(uint256 newMaxFraction);
    event SilicaPools__TreasuryAddressChanged(address newTreasuryAddress);
    event SilicaPools__PauseProtocol();
    event SilicaPools__UnpauseProtocol();

    event SilicaPools__OrderCancelled(bytes32 indexed orderHash);

    event SilicaPools__PoolStarted(
        bytes32 indexed poolHash,
        uint128 floor,
        uint128 cap,
        uint48 targetStartTime,
        uint48 targetEndTime,
        address indexed index,
        address indexed payoutToken,
        uint128 indexShares,
        uint128 indexInitialBalance
    );

    event SilicaPools__BountyPaid(bytes32 indexed poolHash, uint256 bountyAmount, address receiver);

    event SilicaPools__PoolEnded(bytes32 indexed poolHash, uint256 endingIndexBalance, uint128 balanceChangePerShare);

    event SilicaPools__CollateralizedMint(
        bytes32 indexed poolHash,
        bytes32 indexed orderHash,
        address shortRecipient,
        address longRecipient,
        address indexed payer,
        address payoutToken,
        uint256 sharesMinted,
        uint256 collateralAmount
    );

    event SilicaPools__FillFeePaid(
        address indexed payer,
        bytes32 indexed poolHash,
        bytes32 indexed orderHash,
        uint256 tokenId,
        address tokenPaid,
        uint256 amount
    );

    event SilicaPools__SharesRefunded(
        bytes32 indexed poolHash,
        address indexed recipient,
        address indexed payoutToken,
        uint256 sharesRefunded,
        uint256 payoutTokenAmount
    );

    event SilicaPools__SharesRedeemed(
        bytes32 indexed poolHash,
        address indexed recipient,
        address indexed payoutToken,
        uint256 tokenId,
        uint256 sharesRedeemed,
        uint256 payoutTokenAmount
    );

    event SilicaPools__TradeHistoryEvent(
        bytes32 indexed orderHash,
        address indexed maker,
        address indexed taker,
        bytes32 offeredPoolHash,
        bytes32 requestedPoolHash,
        address offeredIndex,
        address requestedIndex,
        uint256 filledFraction,
        uint256 remainingFraction
    ); // Needed if supporting client-side mutation

    event SilicaPools__VolumeAccountingEvent(
        bytes32 indexed orderHash,
        bytes32 poolHash,
        address indexed index,
        address payoutToken,
        uint256 capMinusFloor,
        uint256 sharesMinted,
        uint256 sharesTransferred,
        address indexed upfrontTokenAddr,
        uint256 upfrontTokenAmount
    );

    // Thrown when two input arrays have different lengths
    error SilicaPools__ArrayLengthMismatch();
    // Thrown when the signature of an order is invalid
    error SilicaPools__InvalidSignature(bytes signature);
    // Thrown when ending a pool that has already finished
    error SilicaPools__PoolAlreadyEnded(bytes32 poolHash);
    // Thrown when starting a pool that has already begun
    error SilicaPools__PoolAlreadyStarted(bytes32 poolHash);
    // Thrown when trying to redeem before pool end
    error SilicaPools__PoolNotEnded(bytes32 poolHash);
    // Thrown when interacting with a cancelled order
    error SilicaPools__OrderIsCancelled(bytes32 orderHash);
    // Thrown when filling an order partially
    error SilicaPools__PartialOrdersNotSupported(bytes32 orderHash);
    // Thrown when filling an order that is expired
    error SilicaPools__OrderExpired(uint256 expiry, uint256 blockTimestamp);
    // Thrown when a caller who is not the maker tries to update an order
    error SilicaPools__InvalidCaller(address caller, address expectedCaller);
    // Thrown when starting a pool before its target start time
    error SilicaPools__TooEarlyToStart(uint256 attemptedTimestamp, uint256 targetTimestamp);
    // Thrown when ending a pool before its target end time
    error SilicaPools__TooEarlyToEnd(uint256 attemptedTimestamp, uint256 targetTimestamp);
    // Thrown when filling an order with protocol that is paused
    error SilicaPools__Paused();

    struct PoolParams {
        // 3 storage slots
        /// @notice The "balance change per share" below which
        ///         long shares pay out 0, and short shares pay out the maximum:
        ///         (cap - floor) * shares
        uint128 floor;
        /// @notice The "balance change per share" above which
        ///         short shares pay out 0, and long shares pay out the maximum:
        ///         (cap - floor) * shares
        uint128 cap;
        /// @notice The address of the contract which reports the tracked balance
        /// @custom:see ISilicaIndex
        address index;
        /// @notice The timestamp (in UNIX seconds) after which the pool may be started
        uint48 targetStartTimestamp;
        /// @notice The timestamp (in UNIX seconds) after which the pool may be ended
        uint48 targetEndTimestamp;
        /// @notice Address of the token in which the payout is denominated
        address payoutToken;
    }

    struct PoolState {
        // 3 storage slots
        /// @notice The amount of collateral minted for this pool
        ///         denominated in `SilicaPool.payoutToken`
        /// @notice Increases on mints
        /// @notice Decreases on bounty payouts
        /// @notice Decreases on collateral refunds
        /// @notice Does *not* decrease on shares redeemed
        /// @dev MUST update at mint, refund, bounty payout
        uint128 collateralMinted;
        /// @notice The amount of tokens/shares that have minted for this pool
        /// @notice Increases on mints
        /// @notice Decreases on collateral refunds
        /// @notice Does *not* decrease on shares redeemed
        /// @dev MUST update at mint, refund
        uint128 sharesMinted;
        /// @notice The number of shares the `index` represents,
        ///         as of the pool actual start
        /// @dev MUST record at pool actual start
        uint128 indexShares;
        /// @dev MUST record at pool actual start
        uint128 indexInitialBalance;
        /// @notice The timestamp (in UNIX seconds) after which the pool was started
        /// @dev MUST record at pool actual start
        uint48 actualStartTimestamp;
        /// @notice The timestamp (in UNIX seconds) after which the pool was ended
        /// @dev MUST record at pool actual end
        uint48 actualEndTimestamp;
        /// @dev MUST record at pool actual end. MUST be pro-rated from
        ///      `actualEndTimestamp - actualStartTimestamp` to
        ///      `targetStartTimestamp - targetStartTimestamp`,
        ///      since the target time range is what the users are buying.
        ///      MUST be clamped between `floor` and `cap`.
        /// @notice Clients SHOULD program defensively in case this failed to be
        ///         clamped between `floor` and `cap`
        uint128 balanceChangePerShare;
    }

    /// @notice !TRADE OFFER!
    ///         i receive: requested long shares, requested upfront amount.
    ///         you receive: offered long shares, offered upfront amount.
    ///         `SilicaOrder` may not be used to offer/request short shares,
    ///         since you can offer short shares by requesting long shares,
    ///         and you can request short shares by offering long shares.
    /// @custom:example To sell stETH yield for upfront USDC, set
    ///                 `offeredIndex` to stETH index and
    ///                 `requestedUpfrontToken` to USDC.
    ///                 Set `requestedIndex` and `offeredUpfrontToken` to 0x0.
    /// @custom:example To buy stETH yield with upfront USDC, set
    ///                 `requestedIndex` to stETH index
    ///                 and `offeredUpfrontToken` to USDC.
    ///                 Set `offeredIndex` and `requestedUpfrontToken` to 0x0.
    /// @custom:example To do a "float-to-float" trade, set both `offeredIndex`
    ///                 and `requestedIndex`. If the `offeredLongShares` is a greater
    ///                 exposure than the `requestedLongShares`, then the
    ///                 `requestedUpfrontAmount` should compensate, and vice versa.
    /// @custom:example To "deleverage", i.e. sell the full balance change without
    ///                 subtracting the `floor`: set both `offeredIndex`
    ///                 and `offeredUpfrontToken`. Set `offeredUpfrontAmount` to
    ///                 `offeredfloor * offeredLongShares`.
    /// @custom:example For a deleveraged float-to-float trade, set all 4 fields:
    ///                 `offeredIndex`, `offeredUpfrontToken`,
    ///                 `requestedIndex`, `requestedUpfrontToken`.
    struct SilicaOrder {
        /// @notice The wallet which created and signed the order,
        ///         i.e. `ecrecover` must return this address.
        ///         Assets are `offered` from the `maker` to takers,
        ///         and `requested` by the `maker` from takers.
        address maker;
        /// @notice If this is 0x0, anyone may fill this order.
        ///         Otherwise, this is a private order and
        ///         only `taker` may fill it.
        address taker; // 0x0 if public order
        uint48 expiry; // UNIX seconds
        /// @notice 0x0 if no upfront amount offered
        address offeredUpfrontToken;
        uint128 offeredUpfrontAmount;
        /// @notice 0x0 if no long shares offered
        PoolParams offeredLongSharesParams;
        uint128 offeredLongShares;
        /// @notice 0x0 if no upfront amount requested
        address requestedUpfrontToken;
        uint128 requestedUpfrontAmount;
        /// @notice 0x0 if no long shares requested
        PoolParams requestedLongSharesParams;
        uint128 requestedLongShares;
    }

    /// @notice Domain separator for EIP-712.
    function domainSeparatorV4() external view returns (bytes32);

    /// @notice The fee, in basis points, for minting long and short shares
    function fillFeeBps() external returns (uint256);

    /// @notice Only callable by owner
    /// @dev MUST emit `SilicaPools__MintFeeChanged`
    /// @param newFeeBps The new fee, in basis points
    function setFillFeeBps(uint256 newFeeBps) external;

    /// @notice The address which receives the mint fees
    function treasuryAddress() external view returns (address);

    /// @notice Only callable by owner
    /// @dev MUST emit `SilicaPools__TreasuryAddressChanged`
    /// @param newTreasury The new address which receives the mint fees
    function setTreasuryAddress(address newTreasury) external;

    /// @notice The grace period, in seconds, after the pool's target start & end times during which no bounties are paid
    function bountyGracePeriod() external view returns (uint256);

    /// @notice Only callable by owner
    /// @dev MUST emit `SilicaPools__GracePeriodChanged`
    /// @param newGracePeriod The new grace period, in seconds
    function setBountyGracePeriod(uint256 newGracePeriod) external;

    /// @notice The maximum bounty, as a fraction of the pool's collateral, that can be paid out
    function maxBountyFraction() external view returns (uint256);

    /// @notice Only callable by owner
    /// @dev MUST emit `SilicaPools__MaxBountyFractionChanged`
    /// @param newMaxFraction The new maximum bounty, as a fraction of the pool's collateral
    function setMaxBountyFraction(uint256 newMaxFraction) external;

    /// @notice The rate at which the bounty as a fraction of collateral increases per second
    function bountyFractionIncreasePerSecond() external view returns (uint256);

    /// @notice Only callable by owner
    /// @dev MUST emit `SilicaPools__BountyIncreaseRateChanged`
    /// @param newIncreaseAmount The new rate at which the bounty as a fraction of collateral increases per second
    function setBountyFractionIncreasePerSecond(uint256 newIncreaseAmount) external;

    /// @notice Pause the protocol. Only callable by owner
    /// @dev MUST emit `SilicaPools__PauseProtocol`
    function pause() external;

    /// @notice Unpause the protocol. Only callable by owner
    /// @dev MUST emit `SilicaPools__UnpauseProtocol`
    function unpause() external;

    /// @notice Returns PoolState struct that matched the input hash
    /// @param poolHash The hash of the pool
    /// @return PoolState struct that matched the input hash
    function poolState(bytes32 poolHash) external view returns (PoolState memory);

    /// @notice Indicates if a given order has been cancelled
    /// @param orderHash The hash of the order
    /// @return True if the order has been cancelled, false otherwise
    function orderCancelled(bytes32 orderHash) external view returns (bool);

    /// @notice Takes collateral from the caller, equal to the maximum payout:
    ///         (cap - floor) * shares
    ///         denominated in `SilicaPool.payoutToken`
    /// @notice The caller must have approved this contract to transfer `SilicaPool.payoutToken`.
    /// @dev MUST emit `SilicaPools__CollateralizedMint`
    /// @param poolParams The pool to mint shares from.
    /// @param shares The number of long and short shares to mint.
    /// @param longRecipient Who should receive the long shares
    ///                      (if 0x0, then `msg.sender` receives)
    /// @param shortRecipient Who should receive the short shares
    ///                       (if 0x0, then `msg.sender` receives)
    function collateralizedMint(
        PoolParams calldata poolParams,
        bytes32 orderHash,
        uint256 shares,
        address longRecipient,
        address shortRecipient
    ) external;

    /// @notice Refunds mint collateral to the caller.
    /// @notice The caller must have approved this contract to transfer their long and short shares.
    /// @dev MUST emit `SilicaPools__SharesRefunded`
    /// @param poolParams The pool to refund from.
    /// @param shares Burn this many long shares and short shares.
    function collateralRefund(PoolParams[] calldata poolParams, uint256[] calldata shares) external;

    /// @notice Refunds mint collateral to the caller from the given pool.
    /// @notice The caller must have approved this contract to transfer long and short shares.
    /// @dev MUST emit `SilicaPools__SharesRefunded`
    /// @param poolParams The pool to refund from.
    function maxCollateralRefund(PoolParams[] calldata poolParams) external;

    /// @notice Transfers all `offeredLongShares`, `offeredUpfrontAmount`,
    ///         `requestedLongShares`, `requestedUpfrontAmount` from/to
    ///         the appropriate parties
    ///         (`offered` should go from `order.maker` to `msg.sender`,
    ///         `requested` should go from `msg.sender` to `order.maker`).
    ///         If `order.taker != 0x0` the order is only fillable by `order.taker`.
    ///         This function SHOULD revert if any fill fails.
    ///         `UpfrontAmount`s SHOULD be transferred before any `LongShares` are minted,
    ///         to reduce the required allowance for minting `LongShares`.
    /// @notice The caller must have approved this contract to transfer `requestedUpfrontToken`.
    /// @notice If the order is private, the caller must be the taker.
    /// @notice The input arrays must match in length.
    /// @dev MUST emit `SilicaPools__TradeHistoryEvent`
    /// @dev MUST emit `SilicaPools__VolumeAccountingEvent`
    /// @param orders The orders to fill.
    /// @param signatures The signature of the order maker.
    /// @param fractions Pass 1e18 to fill 100% of the order.
    function fillOrders(SilicaOrder[] calldata orders, bytes[] calldata signatures, uint256[] calldata fractions)
        external;

    /// @notice Cancels the given orders.
    /// @notice The caller must be the maker of each order.
    /// @dev MUST emit `SilicaPools__OrderCancelled`
    /// @param orders The orders to cancel.
    function cancelOrders(SilicaOrder[] calldata orders) external;

    /// @notice View function to estimate bounty for timely initialization of index tracking.
    /// @return If any of the pools are already started, then returns 0 for all bounties. Otherwise returns each bounty, quoted in the `payoutToken` of the pool.
    /// @dev uncappedBountyFraction = block.timestamp > targetEndTimestamp + gracePeriod ? (block.timestamp - targetEndTimestamp - gracePeriod) * bountyFractionIncreasePerSecond : 0;
    /// @dev bountyFraction = max(uncappedBountyFraction, maxBountyFraction)
    /// @dev bounty = bountyFraction * collateral / 10**18;
    function startBounty(PoolParams[] calldata poolParams) external view returns (uint256[] memory);

    /// @notice Records the starting `ISilicaIndex` state for any of
    ///         the specified pools which have not already been started.
    ///         Caller will be paid a bounty for each pool which was not
    ///         already started if called after the grace period.
    /// @notice Can only be called after pool's target start time.
    /// @dev Search `SilicaPool` for "MUST record at pool actual start".
    /// @dev MUST emit `SilicaPools__PoolStarted`
    /// @param poolParams The pools to start.
    function startPools(PoolParams[] calldata poolParams) external;

    /// @notice View function to estimate bounty for timely finalization of index tracking.
    /// @return If any of the pools are already ended, then returns 0 for all bounties. Otherwise returns each bounty, quoted in the `payoutToken` of the pool.
    /// @dev uncappedBountyFraction = block.timestamp > targetEndTimestamp + gracePeriod ? (block.timestamp - targetEndTimestamp - gracePeriod) * bountyFractionIncreasePerSecond : 0;
    /// @dev bountyFraction = max(uncappedBountyFraction, maxBountyFraction)
    /// @dev bounty = bountyFraction * collateral / 10**18;
    function endBounty(PoolParams[] calldata poolParams) external view returns (uint256[] memory);

    /// @notice Records the ending `ISilicaIndex` state for any of
    ///         the specified pools which have not already been ended.
    ///         Caller will be paid a bounty for each pool which was not
    ///         already ended if called after the grace period.
    /// @notice Can only be called after pool's target end time.
    /// @dev Search `SilicaPool` for "MUST record at pool actual end"
    /// @dev MUST emit `SilicaPools__PoolEnded`
    function endPools(PoolParams[] calldata poolParams) external;

    /// @notice Redeems shares for the payout token.
    /// @notice The caller must have approved this contract to transfer their long and short shares.
    /// @dev MUST emit `SilicaPools__SharesRedeemed`
    /// @param longPoolParams The pools to redeem long shares from.
    /// @param shortPoolParams The pools to redeem short shares from.
    function redeem(PoolParams[] calldata longPoolParams, PoolParams[] calldata shortPoolParams) external;

    /// @notice View function to preview the amount that would be returned for calling `redeemShort()` function.
    /// @param shortParams The paramters of the pool to redeem short positions from.
    /// @param account The address to redeem on behalf of.
    /// @return expectedPayout The amount to be redeemed, denoted in the pool's payoutToken.
    function viewRedeemShort(PoolParams calldata shortParams, address account)
        external
        view
        returns (uint256 expectedPayout);

    /// @notice View function to preview the amount that would be returned for calling `redeemLong()` function.
    /// @param longParams The paramters of the pool to redeem long positions from.
    /// @param account The addresses to redeem on behalf of.
    /// @return expectedPayout The amount to be redeemed, denoted in the pool's payoutToken.
    function viewRedeemLong(PoolParams calldata longParams, address account)
        external
        view
        returns (uint256 expectedPayout);

    /// @notice View function to preview the amount that would be returned for calling `collateralRefund()` function.
    /// @param poolParams The pool to refund from.
    /// @param shares The amount of long and short shares to be burnt.
    /// @return expectedRefunds The amount to be refunded, denoted in the pool's payoutToken.
    function viewCollateralRefund(PoolParams[] calldata poolParams, uint256[] calldata shares)
        external
        view
        returns (uint256[] memory expectedRefunds);

    /// @notice View function to preview the amount that would be returned for calling `maxCollateralRefund()` function
    /// @param poolparams The pool to refund from.
    /// @param accounts The accounts to refund on behalf of.
    /// @return expectedRefund The amount to be refunded, denoted in the pool's payoutToken.
    function viewMaxCollateralRefund(PoolParams[] calldata poolparams, address[] calldata accounts)
        external
        view
        returns (uint256[] memory expectedRefund);
}
