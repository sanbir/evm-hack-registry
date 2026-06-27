// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {IBaseModule} from "./IBaseModule.sol";

/**
 * @title ISquidRouterModule
 * @notice An interface for a Gnosis Safe module that routes token bridge operations through
 * Squid Router (Axelar). It supports: (1) same-chain action execution only;
 * (2) bridge with optional source-chain actions (e.g. approve, wrap) then optional
 * destination-chain actions (e.g. swaps, approvals). Approval and wrap are expressed
 * as explicit actions rather than flags.
 */
interface ISquidRouterModule is IBaseModule {
    /**
     * @notice Parameters required to bridge tokens via Squid Router.
     * @param bridgedTokenSymbol The symbol of the token to bridge (e.g. "USDC"), resolved via Axelar gateway.
     * @param amount The amount of tokens to bridge in the token's smallest unit.
     * @param destinationChain The destination chain identifier/name (Axelar nomenclature).
     * @param gasFeeAmount Native token to send with the bridge call (for bridge and destination execution).
     * @param sourceChainActionParams Actions to run on the source chain before the bridge (e.g. ERC20_APPROVE for the router, NATIVE_WRAP). Executed first; then bridgeCall is invoked.
     * @param destinationChainActionParams Actions to run on the destination chain after the bridge; passed in the bridge payload and executed by this module when Axelar delivers the tokens.
     * @param enableExpress When true, enable Axelar express (Squid boost) routing.
     */
    struct BridgeTokensParams {
        string bridgedTokenSymbol;
        uint256 amount;
        string destinationChain;
        uint256 gasFeeAmount;
        ActionsExecutionParams sourceChainActionParams;
        ActionsExecutionParams destinationChainActionParams;
        bool enableExpress;
    }

    /**
     * @notice Parameters for executing a sequence of actions (same-chain or destination-chain).
     * @param actions Ordered list of actions to execute.
     * @param isStrict When true, the module reverts on first action failure; when false, it emits ActionExecutionFailed and stops without reverting.
     */
    struct ActionsExecutionParams {
        ExecuteAction[] actions;
        bool isStrict;
    }

    /**
     * @notice The type of action to execute (same-chain or destination-chain): Uniswap V2/V3 swaps (exact-in/out), ERC20 or Permit2 approval, native wrap/unwrap.
     */
    enum ExecuteActionType {
        UNI_V2_SWAP_EXACT_IN,
        UNI_V2_SWAP_EXACT_OUT,
        UNI_V3_SWAP_EXACT_IN,
        UNI_V3_SWAP_EXACT_OUT,
        ERC20_APPROVE,
        PERMIT2_APPROVE,
        NATIVE_WRAP,
        NATIVE_UNWRAP
    }

    /**
     * @notice A single action to be executed as part of a same-chain or destination-chain flow.
     * @param actionType The kind of action (swap, approval, wrap, unwrap).
     * @param encodedData The ABI-encoded parameters for the action, interpreted according to `actionType`.
     *        For swap actions (UNI_V2_*, UNI_V3_*), the first decoded parameter is the Universal Router address (must be supported; see isUniversalRouter).
     *        For ERC20_APPROVE and PERMIT2_APPROVE, the spender must be squidRouter, a supported universal router, or permit2 (ERC20_APPROVE only).
     */
    struct ExecuteAction {
        ExecuteActionType actionType;
        bytes encodedData;
    }

    /**
     * @notice Emitted when a Squid Router bridge is successfully executed.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate who initiated the transaction.
     * @param tokenSymbol The bridged token symbol.
     * @param amount The bridged token amount.
     * @param destinationChain The destination chain for the bridged tokens.
     */
    event SquidRouterBridgeTokensExecuted(
        address indexed safe,
        address indexed delegate,
        string tokenSymbol,
        uint256 amount,
        string destinationChain
    );

    /**
     * @notice Emitted when an action in a bridge or destination-chain flow fails during execution.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate who initiated the operation.
     * @param actionIndex The index of the action that failed within the actions array.
     * @param actionType The type of the action that failed.
     */
    event ActionExecutionFailed(
        address indexed safe,
        address indexed delegate,
        uint256 actionIndex,
        ExecuteActionType actionType
    );

    /**
     * @notice Emitted when an action in a bridge or destination-chain flow is successfully executed.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate who initiated the operation.
     * @param actionIndex The index of the action that was executed within the actions array.
     * @param actionType The type of the action that was executed.
     */
    event ActionExecuted(
        address indexed safe,
        address indexed delegate,
        uint256 actionIndex,
        ExecuteActionType actionType
    );

    /**
     * @notice Thrown when the provided source address does not match the expected caller or safe.
     * @param sourceAddress The invalid source address that was provided or validated.
     */
    error InvalidSourceAddress(address sourceAddress);

    /**
     * @notice Thrown when an action specifies a module address that is not the expected module.
     * @param module The invalid module address that was provided or validated.
     */
    error InvalidModuleAddress(address module);

    /**
     * @notice Thrown when an approval action specifies a spender that is not allowed (must be squidRouter, a supported universal router — see getSupportedUniversalRouters — or permit2 for ERC20_APPROVE; squidRouter or a supported universal router for PERMIT2_APPROVE).
     * @param spender The disallowed spender address.
     */
    error InvalidSpender(address spender);

    /**
     * @notice Thrown when an action fails while isStrict is true in ActionsExecutionParams.
     * @param actionIndex The index of the action that failed within the actions array.
     * @param actionType The type of the action that failed.
     */
    error FailedToExecuteAction(uint256 actionIndex, ExecuteActionType actionType);

    /**
     * @notice Executes a sequence of actions on the same chain (no bridge). Used for swaps, approvals, wrap/unwrap on the current chain.
     * @param safe The address of the Gnosis Safe.
     * @param params An `ActionsExecutionParams` struct (actions and isStrict).
     */
    function executeSameChainActions(
        address safe,
        ActionsExecutionParams calldata params
    ) external;

    /**
     * @notice Executes source-chain actions, then bridges tokens via Squid Router; destination-chain actions are run by the module when the bridge delivers tokens.
     * @param safe The address of the Gnosis Safe.
     * @param params A `BridgeTokensParams` struct (bridge params plus sourceChainActionParams and destinationChainActionParams).
     */
    function executeSquidRouterBridgeWithActions(
        address safe,
        BridgeTokensParams calldata params
    ) external;

    /**
     * @notice Returns the list of Universal Router addresses that can be used for swap actions and as approve spenders.
     * @return The array of supported Universal Router addresses (may differ per chain after deployment).
     */
    function getSupportedUniversalRouters() external view returns (address[] memory);

    /**
     * @notice Returns whether the given address is a supported Universal Router.
     * @param router The address to check.
     * @return True if the address is in the supported set, false otherwise.
     */
    function isUniversalRouter(address router) external view returns (bool);
}
