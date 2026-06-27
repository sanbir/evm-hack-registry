// SPDX-License-Identifier: MIT
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
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {ERC1155} from "@openzeppelin/token/ERC1155/ERC1155.sol";
import {ECDSA} from "@openzeppelin/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/utils/cryptography/EIP712.sol";
import {Ownable2Step} from "@openzeppelin/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";

import {PoolMaths} from "../libraries/PoolMaths.sol";
import {ISilicaPools} from "../interfaces/ISilicaPools.sol";
import {ISilicaIndex} from "../interfaces/ISilicaIndex.sol";

contract SilicaPools is ISilicaPools, ERC1155, EIP712, Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    bytes32 constant SILICA_POOL_TYPEHASH = keccak256(
        "PoolParams(uint128 floor,uint128 cap,address index,uint48 targetStartTimestamp,uint48 targetEndTimestamp,address payoutToken)"
    ); // The typehash for the PoolParams struct

    bytes32 constant SILICA_ORDER_TYPEHASH = keccak256(
        "SilicaOrder(address maker,address taker,uint48 expiry,address offeredUpfrontToken,uint128 offeredUpfrontAmount,uint128 offeredLongShares,PoolParams offeredLongSharesParams,address requestedUpfrontToken,uint128 requestedUpfrontAmount,uint128 requestedLongShares,PoolParams requestedLongSharesParams)PoolParams(uint128 floor,uint128 cap,address index,uint48 targetStartTimestamp,uint48 targetEndTimestamp,address payoutToken)"
    ); // The typehash for the SilicaOrder struct

    bytes32 public constant TOKENID_SALT = bytes32(uint256(0xAC1D));
    // The salt for token ID derivation

    // Mint fee = mintFeeBps / INVERSE_BASIS_POINT
    // 1 basis point = 0.01% of the collateral
    // 10_000 basis points make up 100%
    uint256 public constant INVERSE_BASIS_POINT = 10_000;

    uint256 private sFillFeeBps; // The fee in basis points for minting long and short tokens
    uint256 public constant MAX_FILL_FEE_BPS = 1000; // 10%
    address private sAlkimiyaTreasury; // The address to which mint fees are sent

    mapping(bytes32 poolHash => PoolState state) private sPoolState;
    mapping(bytes32 orderHash => bool isCancelled) private sOrderCancelled;
    mapping(bytes32 orderHash => uint256 fraction) private sFilledFraction;

    uint256 public sBountyGracePeriod; // The grace period before bounties are paid out, in seconds
    uint256 public sMaxBountyFraction; // The maximum fraction of collateral that can be paid out as a bounty
    uint256 public sBountyFractionIncreasePerSecond; // The rate at which the bounty fraction increases per second, until it reached sMaxBountyFraction.

    bool public paused;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 startFeeBps,
        address initialOwner,
        address alkimiyaTreasury,
        uint256 gracePeriod,
        uint256 maxBountyFrac,
        uint256 bountyIncreasePerSecond
    ) ERC1155("") Ownable(initialOwner) EIP712("SilicaPools", "1") {
        assert(alkimiyaTreasury != address(0));
        sAlkimiyaTreasury = alkimiyaTreasury;

        assert(startFeeBps <= MAX_FILL_FEE_BPS);
        sFillFeeBps = startFeeBps;

        sBountyGracePeriod = gracePeriod;
        sMaxBountyFraction = maxBountyFrac;
        sBountyFractionIncreasePerSecond = bountyIncreasePerSecond;

        emit SilicaPools__FillFeeChanged(startFeeBps);
        emit SilicaPools__GracePeriodChanged(sBountyGracePeriod);
        emit SilicaPools__TreasuryAddressChanged(alkimiyaTreasury);
        emit SilicaPools__MaxBountyFractionChanged(sMaxBountyFraction);
        emit SilicaPools__BountyIncreaseRateChanged(sBountyFractionIncreasePerSecond);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISilicaPools
    function setFillFeeBps(uint256 newFillFeeBps) external onlyOwner {
        if (newFillFeeBps > MAX_FILL_FEE_BPS) {
            revert("Cannot exceed max fee BPS");
        }
        sFillFeeBps = newFillFeeBps;
        emit SilicaPools__FillFeeChanged(newFillFeeBps);
    }

    /// @inheritdoc ISilicaPools
    function setTreasuryAddress(address newTreasury) external onlyOwner {
        assert(newTreasury != address(0));
        sAlkimiyaTreasury = newTreasury;
        emit SilicaPools__TreasuryAddressChanged(newTreasury);
    }

    /// @inheritdoc ISilicaPools
    function setBountyGracePeriod(uint256 newGracePeriod) external onlyOwner {
        sBountyGracePeriod = newGracePeriod;
        emit SilicaPools__GracePeriodChanged(sBountyGracePeriod);
    }

    /// @inheritdoc ISilicaPools
    function setMaxBountyFraction(uint256 newMaxFraction) external onlyOwner {
        sMaxBountyFraction = newMaxFraction;
        emit SilicaPools__MaxBountyFractionChanged(sMaxBountyFraction);
    }

    /// @inheritdoc ISilicaPools
    function setBountyFractionIncreasePerSecond(uint256 newIncreaseAmount) external onlyOwner {
        sBountyFractionIncreasePerSecond = newIncreaseAmount;
        emit SilicaPools__BountyIncreaseRateChanged(sBountyFractionIncreasePerSecond);
    }

    /// @inheritdoc ISilicaPools
    function pause() external onlyOwner {
        paused = true;
        emit SilicaPools__PauseProtocol();
    }

    /// @inheritdoc ISilicaPools
    function unpause() external onlyOwner {
        paused = false;
        emit SilicaPools__UnpauseProtocol();
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISilicaPools
    function startPools(PoolParams[] calldata poolParams) external {
        for (uint256 i = 0; i < poolParams.length; ++i) {
            startPool(poolParams[i]);
        }
    }

    /// @dev calls `_collateralizedMint` with `msg.sender` as `payer`
    /// @inheritdoc ISilicaPools
    function collateralizedMint(
        PoolParams calldata poolParams,
        bytes32 orderHash,
        uint256 shares,
        address longRecipient,
        address shortRecipient
    ) external {
        _collateralizedMint(poolParams, orderHash, shares, msg.sender, longRecipient, shortRecipient);
    }

    /// @inheritdoc ISilicaPools
    function maxCollateralRefund(PoolParams[] calldata poolParams) external nonReentrant {
        for (uint256 i; i < poolParams.length; ++i) {
            bytes32 poolHash = hashPool(poolParams[i]);

            uint256 longBalance = balanceOf(msg.sender, toLongTokenId(poolHash));
            uint256 shortBalance = balanceOf(msg.sender, toShortTokenId(poolHash));

            _collateralRefund(poolParams[i], longBalance < shortBalance ? longBalance : shortBalance);
        }
    }

    /// @inheritdoc ISilicaPools
    function cancelOrders(SilicaOrder[] calldata orders) external {
        for (uint256 i = 0; i < orders.length; ++i) {
            SilicaOrder calldata order = orders[i];

            if (order.maker != msg.sender) {
                revert SilicaPools__InvalidCaller(msg.sender, order.maker);
            }

            bytes32 orderHash = hashOrder(order, _domainSeparatorV4());

            sOrderCancelled[orderHash] = true;
            emit SilicaPools__OrderCancelled(orderHash);
        }
    }

    /// @inheritdoc ISilicaPools
    function fillOrders(SilicaOrder[] calldata orders, bytes[] calldata signatures, uint256[] calldata fractions)
        external
    {
        if (orders.length != signatures.length || orders.length != fractions.length) {
            revert SilicaPools__ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < orders.length; ++i) {
            fillOrder(orders[i], signatures[i], fractions[i]);
        }
    }

    /// @inheritdoc ISilicaPools
    function endPools(PoolParams[] calldata poolParams) external {
        for (uint256 i = 0; i < poolParams.length; ++i) {
            endPool(poolParams[i]);
        }
    }

    /// @inheritdoc ISilicaPools
    function redeem(PoolParams[] calldata longPoolParams, PoolParams[] calldata shortPoolParams) external {
        for (uint256 i = 0; i < longPoolParams.length; ++i) {
            redeemLong(longPoolParams[i]);
        }
        for (uint256 i = 0; i < shortPoolParams.length; ++i) {
            redeemShort(shortPoolParams[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISilicaPools
    function poolState(bytes32 poolHash) external view returns (PoolState memory) {
        return sPoolState[poolHash];
    }

    /// @inheritdoc ISilicaPools
    function startBounty(PoolParams[] calldata poolParams) external view returns (uint256[] memory) {
        uint256[] memory bounties = new uint256[](poolParams.length);
        for (uint256 i = 0; i < poolParams.length; ++i) {
            bounties[i] = _startBounty(poolParams[i]);
        }
        return bounties;
    }

    /// @inheritdoc ISilicaPools
    function endBounty(PoolParams[] calldata poolParams) external view returns (uint256[] memory) {
        uint256[] memory bounties = new uint256[](poolParams.length);
        for (uint256 i = 0; i < poolParams.length; ++i) {
            bounties[i] = _endBounty(poolParams[i]);
        }
        return bounties;
    }

    /// @inheritdoc ISilicaPools
    function viewRedeemShort(PoolParams calldata shortParams, address account)
        external
        view
        returns (uint256 expectedPayout)
    {
        bytes32 poolHash = hashPool(shortParams);
        PoolState storage sState = sPoolState[poolHash];

        // Pool not yet ended
        if (sState.actualEndTimestamp == 0) {
            revert SilicaPools__PoolNotEnded(poolHash);
        }

        uint256 shortTokenId = toShortTokenId(poolHash);
        uint256 shortSharesBalance = balanceOf(account, shortTokenId);

        // Short payouts pay ((cap - balanceChangePerShare) * collateralMinted) / ((cap - floor)) * shortSharesBalance) / totalSharesMinted)
        expectedPayout = PoolMaths.shortPayout(shortParams, sState, shortSharesBalance);
    }

    /// @inheritdoc ISilicaPools
    function viewRedeemLong(PoolParams calldata longParams, address account)
        external
        view
        returns (uint256 expectedPayout)
    {
        bytes32 poolHash = hashPool(longParams);
        PoolState storage sState = sPoolState[poolHash];

        // Pool not yet ended
        if (sState.actualEndTimestamp == 0) {
            revert SilicaPools__PoolNotEnded(poolHash);
        }

        uint256 longTokenId = toLongTokenId(poolHash);
        uint256 longSharesBalance = balanceOf(account, longTokenId);

        // Long payouts pay ((balanceChangePerShare - floor) * collateralMinted) / ((cap - floor) * userLongBalance) / totalSharesMinted)
        expectedPayout = PoolMaths.longPayout(longParams, sState, longSharesBalance);
    }

    /// @inheritdoc ISilicaPools
    function viewCollateralRefund(PoolParams[] calldata poolParams, uint256[] calldata shares)
        external
        view
        returns (uint256[] memory expectedRefunds)
    {
        if (poolParams.length != shares.length) {
            revert SilicaPools__ArrayLengthMismatch();
        }

        expectedRefunds = new uint256[](poolParams.length);
        for (uint256 i; i < poolParams.length; ++i) {
            bytes32 poolHash = hashPool(poolParams[i]);
            ISilicaPools.PoolState storage sState = sPoolState[poolHash];

            uint256 refundCollateral = (uint256(sState.collateralMinted) * shares[i]) / uint256(sState.sharesMinted);

            expectedRefunds[i] = refundCollateral;
        }
    }

    /// @inheritdoc ISilicaPools
    function viewMaxCollateralRefund(PoolParams[] calldata poolParams, address[] calldata accounts)
        external
        view
        returns (uint256[] memory expectedRefund)
    {
        if (poolParams.length != accounts.length) {
            revert SilicaPools__ArrayLengthMismatch();
        }

        expectedRefund = new uint256[](poolParams.length);

        for (uint256 i; i < poolParams.length; ++i) {
            bytes32 poolHash = hashPool(poolParams[i]);

            uint256 longBalance = balanceOf(msg.sender, toLongTokenId(poolHash));
            uint256 shortBalance = balanceOf(msg.sender, toShortTokenId(poolHash));

            ISilicaPools.PoolState storage sState = sPoolState[poolHash];

            if (longBalance < shortBalance) {
                expectedRefund[i] = (uint256(sState.collateralMinted) * longBalance) / uint256(sState.sharesMinted);
            } else {
                expectedRefund[i] = (uint256(sState.collateralMinted) * shortBalance) / uint256(sState.sharesMinted);
            }
        }
    }

    /// @inheritdoc ISilicaPools
    function fillFeeBps() external view returns (uint256) {
        return sFillFeeBps;
    }

    /// @inheritdoc ISilicaPools
    function treasuryAddress() external view returns (address) {
        return sAlkimiyaTreasury;
    }

    /// @inheritdoc ISilicaPools
    function bountyGracePeriod() external view returns (uint256) {
        return sBountyGracePeriod;
    }

    /// @inheritdoc ISilicaPools
    function maxBountyFraction() external view returns (uint256) {
        return sMaxBountyFraction;
    }

    /// @inheritdoc ISilicaPools
    function bountyFractionIncreasePerSecond() external view returns (uint256) {
        return sBountyFractionIncreasePerSecond;
    }

    /// @inheritdoc ISilicaPools
    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ISilicaPools
    function orderCancelled(bytes32 orderHash) external view returns (bool) {
        return sOrderCancelled[orderHash];
    }

    /*//////////////////////////////////////////////////////////////
                           PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Starts the pool that matches the given parameters.
    /// @notice Records the starting `ISilicaIndex` state for any of
    ///         the specified pools which have not already been started.
    ///         Caller will be paid a bounty for each pool which was not
    ///         already started if called after the grace period.
    /// @dev The pool must not have already started.
    /// @dev MUST emit a `PoolStarted` event.
    /// @dev Can only be called at or after the pools target start timestamp.
    /// @param poolParams The paramter struct for the associated pool
    function startPool(PoolParams calldata poolParams) public {
        bytes32 poolHash = hashPool(poolParams);
        PoolState storage sState = sPoolState[poolHash];

        ISilicaIndex index = ISilicaIndex(poolParams.index);

        if (block.timestamp < poolParams.targetStartTimestamp) {
            revert SilicaPools__TooEarlyToStart(block.timestamp, poolParams.targetStartTimestamp);
        }
        if (sState.actualStartTimestamp != 0) {
            revert SilicaPools__PoolAlreadyStarted(poolHash);
        }

        sState.actualStartTimestamp = uint48(block.timestamp);

        sState.indexShares = uint128(index.shares());
        sState.indexInitialBalance = uint128(index.balance());

        uint256 startBountyAmount = _startBounty(poolParams);

        sState.collateralMinted -= uint128(startBountyAmount);

        SafeERC20.safeTransfer(IERC20(poolParams.payoutToken), msg.sender, startBountyAmount);
        emit SilicaPools__BountyPaid(poolHash, startBountyAmount, msg.sender);

        emit SilicaPools__PoolStarted(
            poolHash,
            poolParams.floor,
            poolParams.cap,
            poolParams.targetStartTimestamp,
            poolParams.targetEndTimestamp,
            address(index),
            poolParams.payoutToken,
            sState.indexShares,
            sState.indexInitialBalance
        );
    }

    /// @notice Ends the pool that matches the given parameters.
    /// @notice Records the ending `ISilicaIndex` state for the pool.
    ///         Caller will be paid a bounty for each pool which was not
    ///         already ended if called after the grace period.
    /// @dev The pool must not have already ended.
    /// @dev Can only be called at or after the pools target end timestamp.
    /// @dev MUST emit a `PoolEnded` event.
    /// @param poolParams The paramter struct for the associated pool
    function endPool(PoolParams calldata poolParams) public {
        bytes32 poolHash = hashPool(poolParams);
        PoolState storage sState = sPoolState[poolHash];

        ISilicaIndex index = ISilicaIndex(poolParams.index);

        if (sState.actualEndTimestamp != 0) {
            revert SilicaPools__PoolAlreadyEnded(poolHash);
        }
        if (block.timestamp < poolParams.targetEndTimestamp) {
            revert SilicaPools__TooEarlyToEnd(block.timestamp, poolParams.targetEndTimestamp);
        }
        uint256 indexBalanceAtEnd = index.balance();
        sState.balanceChangePerShare = uint128(
            PoolMaths.balanceChangePerShare(
                indexBalanceAtEnd,
                sState.indexInitialBalance,
                sState.indexShares,
                index.decimals(),
                poolParams.floor,
                poolParams.cap
            )
        );

        sState.actualEndTimestamp = uint48(block.timestamp);

        uint256 endBountyAmount = _endBounty(poolParams);
        sState.collateralMinted -= uint128(endBountyAmount);

        SafeERC20.safeTransfer(IERC20(poolParams.payoutToken), msg.sender, endBountyAmount);
        emit SilicaPools__BountyPaid(poolHash, endBountyAmount, msg.sender);

        emit SilicaPools__PoolEnded(poolHash, indexBalanceAtEnd, sState.balanceChangePerShare);
    }

    /// @notice Fills the order with the given parameters.
    /// @notice Transfers the collateral and mints the long and short tokens
    /// @dev Emits a `TradeHistoryEvent` and a `VolumeAccountingEvent`.
    /// @dev The order must not have already been filled.
    /// @dev The order must not have been cancelled.
    /// @dev The order must not have expired.
    /// @dev The signature must be valid.
    /// @param order The order to fill
    /// @param signature The signature of the order
    /// @param fraction The fraction of the order to fill. Pass 1e18 to fill 100% of the order.
    function fillOrder(SilicaOrder calldata order, bytes calldata signature, uint256 fraction) public nonReentrant {
        if (paused) {
            revert SilicaPools__Paused();
        }
        bytes32 orderHash = hashOrder(order, _domainSeparatorV4());

        // Order validation
        if (fraction != 1e18) {
            revert SilicaPools__PartialOrdersNotSupported(orderHash);
        }
        if (sOrderCancelled[orderHash]) {
            revert SilicaPools__OrderIsCancelled(orderHash);
        }
        if (ECDSA.recover(orderHash, signature) != order.maker) {
            revert SilicaPools__InvalidSignature(signature);
        }
        if (order.taker != address(0) && order.taker != msg.sender) {
            revert SilicaPools__InvalidCaller(msg.sender, order.taker);
        }
        if (order.expiry < block.timestamp) {
            revert SilicaPools__OrderExpired(order.expiry, block.timestamp);
        }
        if (sPoolState[hashPool(order.offeredLongSharesParams)].actualEndTimestamp != 0) {
            revert SilicaPools__PoolAlreadyEnded(hashPool(order.offeredLongSharesParams));
        }
        if (sPoolState[hashPool(order.requestedLongSharesParams)].actualEndTimestamp != 0) {
            revert SilicaPools__PoolAlreadyEnded(hashPool(order.requestedLongSharesParams));
        }

        // Token transfers
        // The long side pays the upfront token amount as collateral to the short side
        if (order.offeredUpfrontAmount != 0) {
            SafeERC20.safeTransferFrom(
                IERC20(order.offeredUpfrontToken),
                order.maker,
                msg.sender,
                (uint256(order.offeredUpfrontAmount) * fraction) / 1e18
            );
        }
        if (order.requestedUpfrontAmount != 0) {
            SafeERC20.safeTransferFrom(
                IERC20(order.requestedUpfrontToken),
                msg.sender,
                order.maker,
                (uint256(order.requestedUpfrontAmount) * fraction) / 1e18
            );
        }

        // Token mints
        // The short side pays the entire collateral into the pool
        if (order.offeredLongShares != 0) {
            // Transfer fees for offered long shares
            uint256 indexDecimals = ISilicaIndex(order.offeredLongSharesParams.index).decimals();

            uint256 collateral = PoolMaths.collateral(
                true,
                order.offeredLongSharesParams.floor,
                order.offeredLongSharesParams.cap,
                (uint256(order.offeredLongShares) * fraction) / 1e18,
                indexDecimals
            );

            // Taker pays the surcharge
            uint256 surcharge = (collateral * sFillFeeBps) / INVERSE_BASIS_POINT;
            SafeERC20.safeTransferFrom(
                IERC20(order.offeredLongSharesParams.payoutToken), msg.sender, sAlkimiyaTreasury, surcharge
            );
            uint256 tokenId = toShortTokenId(hashPool(order.offeredLongSharesParams));
            emit SilicaPools__FillFeePaid(
                msg.sender,
                hashPool(order.offeredLongSharesParams),
                orderHash,
                tokenId,
                order.offeredLongSharesParams.payoutToken,
                surcharge
            );

            // TODO: SImP 7
            _collateralizedMint(
                order.offeredLongSharesParams,
                orderHash,
                (uint256(order.offeredLongShares) * fraction) / 1e18,
                order.maker, // maker pays collateral
                msg.sender, // e.g. taker = buys yield = longRecipient
                order.maker // e.g. maker = sells (offers) yield = shortRecipient
            );
        }
        if (order.requestedLongShares != 0) {
            // Transfer fees for requested long shares
            uint256 indexDecimals = ISilicaIndex(order.requestedLongSharesParams.index).decimals();

            uint256 collateral = PoolMaths.collateral(
                true,
                order.requestedLongSharesParams.floor,
                order.requestedLongSharesParams.cap,
                (uint256(order.requestedLongShares) * fraction) / 1e18,
                indexDecimals
            );

            // Taker pays the surcharge
            uint256 surcharge = (collateral * sFillFeeBps) / INVERSE_BASIS_POINT;
            SafeERC20.safeTransferFrom(
                IERC20(order.requestedLongSharesParams.payoutToken), msg.sender, sAlkimiyaTreasury, surcharge
            );
            uint256 tokenId = toLongTokenId(hashPool(order.requestedLongSharesParams));
            emit SilicaPools__FillFeePaid(
                msg.sender,
                hashPool(order.requestedLongSharesParams),
                orderHash,
                tokenId,
                order.requestedLongSharesParams.payoutToken,
                surcharge
            );

            // TODO: SImP 7
            _collateralizedMint(
                order.requestedLongSharesParams,
                orderHash,
                (uint256(order.requestedLongShares) * fraction) / 1e18,
                msg.sender, // taker pays collateral
                order.maker, // e.g. maker = buys (requests) yield = longRecipient
                msg.sender // e.g. taker = sells yield = shortRecipient
            );
        }

        {
            uint256 newFilledFraction = sFilledFraction[orderHash] + fraction;
            sFilledFraction[orderHash] = newFilledFraction;

            emit SilicaPools__TradeHistoryEvent(
                orderHash,
                order.maker,
                msg.sender,
                hashPool(order.offeredLongSharesParams),
                hashPool(order.requestedLongSharesParams),
                order.offeredLongSharesParams.index,
                order.requestedLongSharesParams.index,
                fraction,
                1e18 - newFilledFraction
            );
        }

        if (order.offeredLongShares > 0 || order.requestedUpfrontAmount > 0) {
            emit SilicaPools__VolumeAccountingEvent(
                orderHash,
                hashPool(order.offeredLongSharesParams),
                order.offeredLongSharesParams.index,
                order.offeredLongSharesParams.payoutToken,
                order.offeredLongSharesParams.cap - order.offeredLongSharesParams.floor,
                (order.offeredLongShares * fraction) / 1e18,
                (order.offeredLongShares * fraction) / 1e18,
                order.requestedUpfrontToken,
                (order.requestedUpfrontAmount * fraction) / 1e18
            );
        }

        if (order.requestedLongShares > 0 || order.offeredUpfrontAmount > 0) {
            emit SilicaPools__VolumeAccountingEvent(
                orderHash,
                hashPool(order.requestedLongSharesParams),
                order.requestedLongSharesParams.index,
                order.requestedLongSharesParams.payoutToken,
                order.requestedLongSharesParams.cap - order.requestedLongSharesParams.floor,
                (order.requestedLongShares * fraction) / 1e18,
                (order.requestedLongShares * fraction) / 1e18,
                order.offeredUpfrontToken,
                (order.offeredUpfrontAmount * fraction) / 1e18
            );
        }
    }

    /// @notice Redeems shares for the payout token.
    /// @dev MUST emit `SilicaPools__SharesRedeemed`
    /// @param longParams The pools to redeem long shares from.
    function redeemLong(PoolParams calldata longParams) public {
        bytes32 poolHash = hashPool(longParams);
        PoolState storage sState = sPoolState[poolHash];

        if (sState.actualEndTimestamp == 0) {
            revert SilicaPools__PoolNotEnded(poolHash);
        }

        uint256 longTokenId = toLongTokenId(poolHash);
        uint256 longSharesBalance = balanceOf(msg.sender, longTokenId);
        // Long payouts pay ((balanceChangePerShare - floor) * collateralMinted) / ((cap - floor) * userLongBalance) / totalSharesMinted)
        uint256 payout = PoolMaths.longPayout(longParams, sState, longSharesBalance);

        _burn(msg.sender, longTokenId, longSharesBalance);

        SafeERC20.safeTransfer(IERC20(longParams.payoutToken), msg.sender, payout);

        emit SilicaPools__SharesRedeemed(
            poolHash, msg.sender, longParams.payoutToken, longTokenId, longSharesBalance, payout
        );
    }

    /// @notice Redeems shares for the payout token.
    /// @dev MUST emit `SilicaPools__SharesRedeemed`
    /// @param shortParams The pools to redeem short shares from.
    function redeemShort(PoolParams calldata shortParams) public {
        bytes32 poolHash = hashPool(shortParams);
        PoolState storage sState = sPoolState[poolHash];

        if (sState.actualEndTimestamp == 0) {
            revert SilicaPools__PoolNotEnded(poolHash);
        }

        uint256 shortTokenId = toShortTokenId(poolHash);
        uint256 shortSharesBalance = balanceOf(msg.sender, shortTokenId);

        // Short payouts pay ((cap - balanceChangePerShare) * collateralMinted) / ((cap - floor)) * shortSharesBalance) / totalSharesMinted)
        uint256 payout = PoolMaths.shortPayout(shortParams, sState, shortSharesBalance);

        _burn(msg.sender, shortTokenId, shortSharesBalance);

        SafeERC20.safeTransfer(IERC20(shortParams.payoutToken), msg.sender, payout);

        emit SilicaPools__SharesRedeemed(
            poolHash, msg.sender, shortParams.payoutToken, shortTokenId, shortSharesBalance, payout
        );
    }

    /// @inheritdoc ISilicaPools
    function collateralRefund(PoolParams[] calldata poolParams, uint256[] calldata shares) public nonReentrant {
        if (poolParams.length != shares.length) {
            revert SilicaPools__ArrayLengthMismatch();
        }

        for (uint256 i; i < poolParams.length; ++i) {
            _collateralRefund(poolParams[i], shares[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC PURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts a pool hash to a long token ID.
    /// @param poolHash The hash of the pool.
    /// @return The long token ID.
    function toLongTokenId(bytes32 poolHash) public pure returns (uint256) {
        return uint256(poolHash);
    }

    /// @notice Converts a pool hash to a short token ID.
    /// @param poolHash The hash of the pool.
    /// @return The short token ID.
    function toShortTokenId(bytes32 poolHash) public pure returns (uint256) {
        return uint256(poolHash ^ TOKENID_SALT);
    }

    /// @notice Converts a long token ID to a pool hash.
    /// @param longTokenId The long token ID.
    /// @return The pool hash.
    function fromLongTokenId(uint256 longTokenId) public pure returns (bytes32) {
        return bytes32(longTokenId);
    }

    /// @notice Converts a short token ID to a pool hash.
    /// @param shortTokenId The short token ID.
    /// @return The pool hash.
    function fromShortTokenId(uint256 shortTokenId) public pure returns (bytes32) {
        return bytes32(shortTokenId) ^ TOKENID_SALT;
    }

    /// @notice Hashes the pool parameters.
    /// @param poolParams The pool parameters.
    /// @return The hash of the pool parameters.
    function hashPool(PoolParams calldata poolParams) public pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                poolParams.floor,
                poolParams.cap,
                poolParams.index,
                poolParams.targetStartTimestamp,
                poolParams.targetEndTimestamp,
                poolParams.payoutToken
            )
        );
    }

    /// @notice Hashes the order parameters.
    /// @param order The order parameters.
    /// @param domainSeparator The EIP-712 domain separator.
    /// @return The hash of the order parameters.
    function hashOrder(SilicaOrder calldata order, bytes32 domainSeparator) public pure returns (bytes32) {
        // Encode in chunks to circumvent "stack too deep" error
        bytes32 offeredStructHash = keccak256(abi.encode(SILICA_POOL_TYPEHASH, order.offeredLongSharesParams));
        bytes32 requestedStructHash = keccak256(abi.encode(SILICA_POOL_TYPEHASH, order.requestedLongSharesParams));
        bytes32 structHash = keccak256(
            abi.encode(
                SILICA_ORDER_TYPEHASH,
                order.maker,
                order.taker,
                order.expiry,
                order.offeredUpfrontToken,
                order.offeredUpfrontAmount,
                order.offeredLongShares,
                offeredStructHash,
                order.requestedUpfrontToken,
                order.requestedUpfrontAmount,
                order.requestedLongShares,
                requestedStructHash
            )
        );

        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to mint long and short tokens for a pool.
    /// @dev This is `internal` because it must be approved by the `payer`.
    ///      Do not call this function otherwise.
    /// @param poolParams The paramter struct for the associated pool
    /// @param payer The address that will pay the collateral
    /// @param longRecipient The address that will receive `shares` long tokens
    /// @param shortRecipient The address that will receive `shares` short tokens
    function _collateralizedMint(
        PoolParams calldata poolParams,
        bytes32 orderHash,
        uint256 shares,
        address payer,
        address longRecipient,
        address shortRecipient
    ) internal {
        bytes32 poolHash = hashPool(poolParams);

        if (sPoolState[poolHash].actualEndTimestamp != 0) {
            revert SilicaPools__PoolAlreadyEnded(poolHash);
        }

        ISilicaIndex index = ISilicaIndex(poolParams.index);
        ISilicaPools.PoolState storage sState = sPoolState[poolHash];

        uint256 collateral = PoolMaths.collateral(true, poolParams.floor, poolParams.cap, shares, index.decimals());

        sState.collateralMinted += uint128(collateral);

        SafeERC20.safeTransferFrom(IERC20(poolParams.payoutToken), payer, address(this), collateral);

        if (longRecipient == address(0)) {
            longRecipient = msg.sender;
        }
        if (shortRecipient == address(0)) {
            shortRecipient = msg.sender;
        }

        sState.sharesMinted += uint128(shares);

        _mint(longRecipient, toLongTokenId(poolHash), shares, "");
        _mint(shortRecipient, toShortTokenId(poolHash), shares, "");

        emit SilicaPools__CollateralizedMint(
            poolHash, orderHash, shortRecipient, longRecipient, payer, poolParams.payoutToken, shares, collateral
        );
    }

    /// @notice Internal calculator to determine bounty value for calling startPool()
    /// @param poolParams The paramter struct for the associated pool
    /// @return bounty The uint256 amount of bounty associated with that pool's collateral
    function _startBounty(PoolParams calldata poolParams) internal view returns (uint256 bounty) {
        bytes32 poolHash = hashPool(poolParams);
        ISilicaPools.PoolState storage sState = sPoolState[poolHash];

        uint256 collateral = sState.collateralMinted;

        uint256 uncappedBountyFraction = block.timestamp > poolParams.targetStartTimestamp + sBountyGracePeriod
            ? uint256(block.timestamp - poolParams.targetStartTimestamp - sBountyGracePeriod)
                * sBountyFractionIncreasePerSecond
            : 0;

        uint256 bountyFraction =
            uncappedBountyFraction > sMaxBountyFraction ? sMaxBountyFraction : uncappedBountyFraction;

        bounty = (bountyFraction * collateral) / 1e18;
    }

    /// @notice Internal bounty calculator function
    /// @param poolParams: The paramter struct for the associated pool
    /// @return bounty The uint256 amount of bounty associated with that pool's collateral
    function _endBounty(PoolParams calldata poolParams) internal view returns (uint256 bounty) {
        bytes32 poolHash = hashPool(poolParams);
        uint256 collateral = sPoolState[poolHash].collateralMinted;

        uint256 uncappedBountyFraction = block.timestamp > poolParams.targetEndTimestamp + sBountyGracePeriod
            ? uint256(block.timestamp - poolParams.targetEndTimestamp - sBountyGracePeriod)
                * sBountyFractionIncreasePerSecond
            : 0;

        uint256 bountyFraction =
            uncappedBountyFraction > sMaxBountyFraction ? sMaxBountyFraction : uncappedBountyFraction;

        bounty = (bountyFraction * collateral) / 1e18;
    }

    /// @notice Internal function to refund collateral to the user.
    /// @dev This is `internal` because it must be approved by the `payer`.
    ///      Do not call this function otherwise.
    /// @dev Called by `collateralRefund()` and `maxCollateralRefund()` with msg.sender as the recipient.
    /// @dev Emits a `SilicaPools__SharesRefunded` event.
    /// @param poolParams The paramter struct for the associated pool.
    /// @param shares The number of shares to refund.
    function _collateralRefund(PoolParams calldata poolParams, uint256 shares) internal {
        bytes32 poolHash = hashPool(poolParams);
        ISilicaPools.PoolState storage sState = sPoolState[poolHash];

        uint256 refundCollateral = (uint256(sState.collateralMinted) * shares) / uint256(sState.sharesMinted);

        sState.sharesMinted -= uint128(shares);

        _burn(msg.sender, toLongTokenId(poolHash), shares);
        _burn(msg.sender, toShortTokenId(poolHash), shares);

        sState.collateralMinted -= uint128(refundCollateral);
        SafeERC20.safeTransfer(IERC20(poolParams.payoutToken), msg.sender, refundCollateral);

        emit SilicaPools__SharesRefunded(poolHash, msg.sender, poolParams.payoutToken, shares, refundCollateral);
    }
}
