// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title SquidRouter
 * @notice Main entry point of the protocol. It mainly provides endpoints to interact safely
 * with the multicall or CCTP, and receiver function to handle asset reception for bridges.
 */
interface ISquidRouter {
    /**
     * @notice Collect ERC20 and/or native tokens from user and send them to multicall. Then bridge tokens
     * through Axelar bridge and run multicall on destination chain. This endpoint is deprecated and will be
     * removed in a future upgrade.
     * @dev Require either ERC20 or permit2 allowance from the user to the router address.
     * Indeed, permit2's transferFrom2 is used instead of regulat transferFrom. Meaning that if there is no
     * regular allowance from user to the router for ERC20 token, permit2 allowance will be used if granted.
     * @dev Require to provide native amount to cover gas service. The amount has to be computed off chain with
     * Axelar SDK.
     * @dev Native tokens provided on top of an ERC20 token will be sent to gas service. Thus you need to provide
     * native amount to cover gas service on top of native amount for calls
     * @dev Gas service providing is handled internally.
     * @param bridgedTokenSymbol Symbol of the token that will be sent to Axelar bridge.
     * @param amount Amount of ERC20 tokens to be collect for bridging.
     * @param destinationChain Destination chain for bridging according to Axelar's nomenclature.
     * @param destinationAddress Address that will receive bridged ERC20 tokens on destination chain.
     * @param payload Bytes value containing calls to be ran by the multicall on destination chain.
     * Expected format is: abi.encode(ISquidMulticall.Call[] calls, address refundRecipient, bytes32 salt).
     * @param gasRefundRecipient Address that will receive native tokens left on gas service after process is
     * done.
     * @param enableExpress If true is provided, Axelar's express (aka Squid's boost) feature will be used.
     */
    function bridgeCall(
        string calldata bridgedTokenSymbol,
        uint256 amount,
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        address gasRefundRecipient,
        bool enableExpress
    ) external payable;
}
