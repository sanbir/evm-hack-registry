// SPDX-License-Identifier: ISC

pragma solidity 0.8.22;
pragma abicoder v2;

// Types
import { Order, OrderInfo } from "../AugustusV6Types.sol";

interface IAugustusRFQ {
    /// @dev Allows taker to fill an order
    /// @param order Order quote to fill
    /// @param signature Signature of the maker corresponding to the order
    function fillOrder(Order calldata order, bytes calldata signature) external;

    /// @dev The same as fillOrder but allows sender to specify the target beneficiary address
    /// @param order Order quote to fill
    /// @param signature Signature of the maker corresponding to the order
    /// @param target Address of the receiver
    function fillOrderWithTarget(Order calldata order, bytes calldata signature, address target) external;

    /// @dev Allows taker to fill an order partially
    /// @param order Order quote to fill
    /// @param signature Signature of the maker corresponding to the order
    /// @param takerTokenFillAmount Maximum taker token to fill this order with.
    function partialFillOrder(
        Order calldata order,
        bytes calldata signature,
        uint256 takerTokenFillAmount
    )
        external
        returns (uint256 makerTokenFilledAmount);

    /// @dev Same as `partialFillOrder` but it allows to specify the destination address
    ///  @param order Order quote to fill
    ///  @param signature Signature of the maker corresponding to the order
    ///  @param takerTokenFillAmount Maximum taker token to fill this order with.
    ///  @param target Address that will receive swap funds
    function partialFillOrderWithTarget(
        Order calldata order,
        bytes calldata signature,
        uint256 takerTokenFillAmount,
        address target
    )
        external
        returns (uint256 makerTokenFilledAmount);

    /// @dev Same as `partialFillOrderWithTarget` but it allows to pass permit
    ///  @param order Order quote to fill
    ///  @param signature Signature of the maker corresponding to the order
    ///  @param takerTokenFillAmount Maximum taker token to fill this order with.
    ///  @param target Address that will receive swap funds
    ///  @param permitTakerAsset Permit calldata for taker
    ///  @param permitMakerAsset Permit calldata for maker
    function partialFillOrderWithTargetPermit(
        Order calldata order,
        bytes calldata signature,
        uint256 takerTokenFillAmount,
        address target,
        bytes calldata permitTakerAsset,
        bytes calldata permitMakerAsset
    )
        external
        returns (uint256 makerTokenFilledAmount);

    /// @dev batch fills orders until the takerFillAmount is swapped
    /// @dev skip the order if it fails
    /// @param orderInfos OrderInfo to fill
    /// @param takerFillAmount total taker amount to fill
    /// @param target Address of receiver

    function tryBatchFillOrderTakerAmount(
        OrderInfo[] calldata orderInfos,
        uint256 takerFillAmount,
        address target
    )
        external;

    /// @dev batch fills orders until the makerFillAmount is swapped
    /// @dev skip the order if it fails
    /// @param orderInfos OrderInfo to fill
    /// @param makerFillAmount total maker amount to fill
    /// @param target Address of receiver
    function tryBatchFillOrderMakerAmount(
        OrderInfo[] calldata orderInfos,
        uint256 makerFillAmount,
        address target
    )
        external;
}
