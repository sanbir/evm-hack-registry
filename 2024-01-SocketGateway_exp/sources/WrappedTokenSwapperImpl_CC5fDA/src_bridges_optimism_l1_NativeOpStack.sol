// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import "../interfaces/optimism.sol";
import {BridgeImplBase} from "../../BridgeImplBase.sol";
import {IOptimismPortal} from "../interfaces/optimism.sol";

/**
 * @title NativeOptimism-Route Implementation
 * @notice Route implementation with functions to bridge ERC20 and Native via NativeOptimism-Bridge
 * Tokens are bridged from Ethereum to Optimism Chain.
 * Called via SocketGateway if the routeId in the request maps to the routeId of NativeOptimism-Implementation
 * Contains function to handle bridging as post-step i.e linked to a preceeding step for swap
 * RequestData is different to just bride and bridging chained with swap
 * @author Socket dot tech.
 */
contract NativeOptimismStack is BridgeImplBase {
    using SafeTransferLib for ERC20;

    uint256 public constant UINT256_MAX = type(uint256).max;

    /// @notice Function-selector for ERC20-token bridging on Native-Optimism-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge ERC20 tokens
    bytes4
        public immutable NATIVE_OPTIMISM_ERC20_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(
            keccak256(
                "bridgeERC20To(address,address,address,uint32,(bytes32,bytes32),uint256,uint256,address,bytes)"
            )
        );

    /// @notice Function-selector for Native bridging on Native-Optimism-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge Native balance
    bytes4
        public immutable NATIVE_OPTIMISM_NATIVE_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(
            keccak256(
                "bridgeNativeTo(address,uint32,uint256,uint256,bytes32,bytes32,bytes)"
            )
        );

    bytes4 public immutable NATIVE_OPTIMISM_SWAP_BRIDGE_SELECTOR =
        bytes4(
            keccak256(
                "swapAndBridge(uint32,bytes,(uint256,bytes32,bytes32,address,address,uint32,address,bytes))"
            )
        );

    IOptimismPortal private immutable optimismPortal;

    /// @notice socketGatewayAddress to be initialised via storage variable BridgeImplBase
    constructor(
        address _socketGateway,
        address _socketDeployFactory,
        address _optimismPortal
    ) BridgeImplBase(_socketGateway, _socketDeployFactory) {
        optimismPortal = IOptimismPortal(_optimismPortal);
    }

    /// @notice Struct to be used in decode step from input parameter - a specific case of bridging after swap.
    /// @dev the data being encoded in offchain or by caller should have values set in this sequence of properties in this struct
    struct OptimismBridgeDataNoToken {
        // socket offchain created hash
        bytes32 metadata;
        // address of receiver of bridged tokens
        address receiverAddress;
        // dest chain id
        uint256 toChainId;
        // bridge identifier
        bytes32 bridgeHash;
        /**
         * OptimismBridge that Performs the logic for deposits by informing the L2 Deposited Token
         * contract of the deposit and calling a handler to lock the L1 funds. (e.g. transferFrom)
         */
        address customBridgeAddress;
        // Gas limit required to complete the deposit on L2.
        uint32 l2Gas;
        // Address of the L1 respective L2 ERC20
        address l2Token;
        // additional data , for ll contracts this will be 0x data or empty data
        bytes data;
    }

    struct OptimismBridgeData {
        // socket offchain created hash
        bytes32 metadata;
        // address of receiver of bridged tokens
        address receiverAddress;
        // dest chain id
        uint256 toChainId;
        // bridge identifier
        bytes32 bridgeHash;
        /**
         * OptimismBridge that Performs the logic for deposits by informing the L2 Deposited Token
         * contract of the deposit and calling a handler to lock the L1 funds. (e.g. transferFrom)
         */
        address customBridgeAddress;
        /// @notice address of token being bridged
        address token;
        // Gas limit required to complete the deposit on L2.
        uint32 l2Gas;
        // Address of the L1 respective L2 ERC20
        address l2Token;
        // additional data , for ll contracts this will be 0x data or empty data
        bytes data;
    }

    /**
     * @notice function to bridge tokens after swap.
     * @notice this is different from swapAndBridge, this function is called when the swap has already happened at a different place.
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @dev for usage, refer to controller implementations
     *      encodedData for bridge should follow the sequence of properties in OptimismBridgeData struct
     * @param amount amount of tokens being bridged. this can be ERC20 or native
     * @param bridgeData encoded data for Optimism-Bridge
     */
    function bridgeAfterSwap(
        uint256 amount,
        bytes calldata bridgeData
    ) external payable override {
        OptimismBridgeData memory optimismBridgeData = abi.decode(
            bridgeData,
            (OptimismBridgeData)
        );

        emit SocketBridge(
            amount,
            optimismBridgeData.token,
            optimismBridgeData.toChainId,
            optimismBridgeData.bridgeHash,
            msg.sender,
            optimismBridgeData.receiverAddress,
            optimismBridgeData.metadata
        );
        if (optimismBridgeData.token == NATIVE_TOKEN_ADDRESS) {
            optimismPortal.depositTransaction{value: amount}(
                optimismBridgeData.receiverAddress,
                amount,
                optimismBridgeData.l2Gas,
                false,
                optimismBridgeData.data
            );
        } else {
            if (
                amount >
                ERC20(optimismBridgeData.token).allowance(
                    address(this),
                    optimismBridgeData.customBridgeAddress
                )
            ) {
                ERC20(optimismBridgeData.token).safeApprove(
                    optimismBridgeData.customBridgeAddress,
                    UINT256_MAX
                );
            }

            // deposit into standard bridge
            L1StandardBridge(optimismBridgeData.customBridgeAddress)
                .depositERC20To(
                    optimismBridgeData.token,
                    optimismBridgeData.l2Token,
                    optimismBridgeData.receiverAddress,
                    amount,
                    optimismBridgeData.l2Gas,
                    optimismBridgeData.data
                );
            return;
        }
    }

    /**
     * @notice function to bridge tokens after swap.
     * @notice this is different from bridgeAfterSwap since this function holds the logic for swapping tokens too.
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @dev for usage, refer to controller implementations
     *      encodedData for bridge should follow the sequence of properties in OptimismBridgeData struct
     * @param swapId routeId for the swapImpl
     * @param swapData encoded data for swap
     * @param optimismBridgeData encoded data for OptimismBridgeData
     */
    function swapAndBridge(
        uint32 swapId,
        bytes calldata swapData,
        OptimismBridgeDataNoToken calldata optimismBridgeData
    ) external payable {
        (bool success, bytes memory result) = socketRoute
            .getRoute(swapId)
            .delegatecall(swapData);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }

        (uint256 bridgeAmount, address token) = abi.decode(
            result,
            (uint256, address)
        );

        emit SocketBridge(
            bridgeAmount,
            token,
            optimismBridgeData.toChainId,
            optimismBridgeData.bridgeHash,
            msg.sender,
            optimismBridgeData.receiverAddress,
            optimismBridgeData.metadata
        );
        if (token == NATIVE_TOKEN_ADDRESS) {
            optimismPortal.depositTransaction{value: bridgeAmount}(
                optimismBridgeData.receiverAddress,
                bridgeAmount,
                optimismBridgeData.l2Gas,
                false,
                optimismBridgeData.data
            );
        } else {
            if (
                bridgeAmount >
                ERC20(token).allowance(
                    address(this),
                    optimismBridgeData.customBridgeAddress
                )
            ) {
                ERC20(token).safeApprove(
                    optimismBridgeData.customBridgeAddress,
                    UINT256_MAX
                );
            }

            // deposit into standard bridge
            L1StandardBridge(optimismBridgeData.customBridgeAddress)
                .depositERC20To(
                    token,
                    optimismBridgeData.l2Token,
                    optimismBridgeData.receiverAddress,
                    bridgeAmount,
                    optimismBridgeData.l2Gas,
                    optimismBridgeData.data
                );
            return;
        }
    }

    /**
     * @notice function to handle ERC20 bridging to receipent via NativeOptimism-Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param token address of token being bridged
     * @param receiverAddress address of receiver of bridged tokens
     * @param customBridgeAddress OptimismBridge that Performs the logic for deposits by informing the L2 Deposited Token
     *                           contract of the deposit and calling a handler to lock the L1 funds. (e.g. transferFrom)
     * @param l2Gas Gas limit required to complete the deposit on L2.
     * @param metadata metadata
     * @param amount amount being bridged
     * @param l2Token Address of the L1 respective L2 ERC20
     * @param data additional data , for ll contracts this will be 0x data or empty data
     */
    function bridgeERC20To(
        address token,
        address receiverAddress,
        address customBridgeAddress,
        uint32 l2Gas,
        bytes32 metadata,
        uint256 amount,
        address l2Token,
        uint256 toChainId,
        bytes32 bridgeHash,
        bytes calldata data
    ) external payable {
        ERC20(token).safeTransferFrom(msg.sender, socketGateway, amount);
        if (
            amount > ERC20(token).allowance(address(this), customBridgeAddress)
        ) {
            ERC20(token).safeApprove(customBridgeAddress, UINT256_MAX);
        }

        emit SocketBridge(
            amount,
            token,
            toChainId,
            bridgeHash,
            msg.sender,
            receiverAddress,
            metadata
        );
        // deposit into standard bridge
        L1StandardBridge(customBridgeAddress).depositERC20To(
            token,
            l2Token,
            receiverAddress,
            amount,
            l2Gas,
            data
        );
        return;
    }

    /**
     * @notice function to handle native balance bridging to receipent via NativeOptimism-Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param receiverAddress address of receiver of bridged tokens
     * @param l2Gas Gas limit required to complete the deposit on L2.
     * @param amount amount being bridged
     * @param data additional data , for ll contracts this will be 0x data or empty data
     */
    function bridgeNativeTo(
        address receiverAddress,
        uint32 l2Gas,
        uint256 amount,
        uint256 toChainId,
        bytes32 metadata,
        bytes32 bridgeHash,
        bytes calldata data
    ) external payable {
        optimismPortal.depositTransaction{value: amount}(
            receiverAddress,
            amount,
            l2Gas,
            false,
            data
        );

        emit SocketBridge(
            amount,
            NATIVE_TOKEN_ADDRESS,
            toChainId,
            bridgeHash,
            msg.sender,
            receiverAddress,
            metadata
        );
    }
}
