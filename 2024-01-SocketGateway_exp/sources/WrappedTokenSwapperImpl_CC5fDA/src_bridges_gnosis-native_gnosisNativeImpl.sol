// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../BridgeImplBase.sol";
import "./interfaces/gnosisBirdge.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {IGnosisXdaiBridge, IGnosisOmniBridge, IGnosisWethOmniBridgeHelper} from "./interfaces/gnosisBirdge.sol";
import {GNOSIS_NATIVE_BRIDGE} from "../../static/RouteIdentifiers.sol";

/**
 * @title Symbiosis-Route Implementation
 * @notice Route implementation with functions to bridge ERC20 and Native via Symbiosis-Bridge
 * Called via SocketGateway if the routeId in the request maps to the routeId of SymbiosisImplementation
 * Contains function to handle bridging as post-step i.e linked to a preceeding step for swap
 * RequestData is different to just bride and bridging chained with swap
 * @author Socket dot tech.
 */

contract GnosisNativeBridgeImpl is BridgeImplBase {
    /// @notice SafeTransferLib - library for safe and optimised operations on ERC20 tokens
    using SafeTransferLib for ERC20;

    bytes32 public immutable GnosisNativeBridgeIdentifier =
        GNOSIS_NATIVE_BRIDGE;

    /// @notice max value for uint256
    uint256 public constant UINT256_MAX = type(uint256).max;

    /// @notice Function-selector for ERC20-token bridging on Symbiosis-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge ERC20 tokens
    bytes4
        public immutable GNOSIS_NATIVE_BRIDGE_ERC20_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(
            keccak256(
                "bridgeERC20To(bytes32,address,address,address,uint256,uint256)"
            )
        );

    /// @notice Function-selector for Native bridging on Symbiosis-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge Native tokens
    bytes4
        public immutable GNOSIS_NATIVE_BRIDGE_NATIVE_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(keccak256("bridgeNativeTo(bytes32,address,uint256,uint256)"));

    bytes4 public immutable GNOSIS_NATIVE_BRIDGE_SWAP_BRIDGE_SELECTOR =
        bytes4(
            keccak256(
                "swapAndBridge(uint32,bytes,bytes32,address,address,uint256)"
            )
        );

    struct GnosisNativeBridgeData {
        bytes32 metadata;
        address receiverAddress;
        address fromTokenAddress;
        address toTokenAddress;
        uint256 toChainId;
        uint256 amount;
    }

    /// @notice The contract address of the Symbiosis router on the source chain
    IGnosisXdaiBridge private immutable gnosisXdaiBridge;
    IGnosisOmniBridge private immutable gnosisOmniBridge;
    IGnosisWethOmniBridgeHelper private immutable gnosisWethOmniBridgeHelper;

    constructor(
        address _gnosisXdaiBridge,
        address _gnosisOmniBridge,
        address _gnosisWethOmniBridgeHelper,
        address _socketGateway,
        address _socketDeployFactory
    ) BridgeImplBase(_socketGateway, _socketDeployFactory) {
        gnosisXdaiBridge = IGnosisXdaiBridge(_gnosisXdaiBridge);
        gnosisOmniBridge = IGnosisOmniBridge(_gnosisOmniBridge);
        gnosisWethOmniBridgeHelper = IGnosisWethOmniBridgeHelper(
            _gnosisWethOmniBridgeHelper
        );
    }

    /**
     * @notice function to handle ERC20 bridging to receipent via Gnosis Native Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param metadata  socket offchain created hash
     * @param receiverAddress address of the token to bridged to the destination chain.
     * @param fromTokenAddress address of token being bridged
     * @param toTokenAddress address of token to receive at dest chain
     * @param toChainId chainId of destination
     * @param amount amount to be bridged
     */
    function bridgeERC20To(
        bytes32 metadata,
        address receiverAddress,
        address fromTokenAddress,
        address toTokenAddress,
        uint256 toChainId,
        uint256 amount
    ) external payable {
        ERC20(fromTokenAddress).safeTransferFrom(
            msg.sender,
            socketGateway,
            amount
        );

        // if from fromToken is DAI on mainnet and
        // toToken is native DAI on Gnosis use xDaiBridge
        if (toTokenAddress == NATIVE_TOKEN_ADDRESS) {
            if (
                amount >
                ERC20(fromTokenAddress).allowance(
                    address(this),
                    address(gnosisXdaiBridge)
                )
            ) {
                ERC20(fromTokenAddress).safeApprove(
                    address(gnosisXdaiBridge),
                    UINT256_MAX
                );
            }

            gnosisXdaiBridge.relayTokens(receiverAddress, amount);
        } else {
            // other ERC20 tokens use omni bridge
            if (
                amount >
                ERC20(fromTokenAddress).allowance(
                    address(this),
                    address(gnosisOmniBridge)
                )
            ) {
                ERC20(fromTokenAddress).safeApprove(
                    address(gnosisOmniBridge),
                    UINT256_MAX
                );
            }

            gnosisOmniBridge.relayTokens(
                fromTokenAddress,
                receiverAddress,
                amount
            );
        }

        emit SocketBridge(
            amount,
            fromTokenAddress,
            toChainId,
            GnosisNativeBridgeIdentifier,
            msg.sender,
            receiverAddress,
            metadata
        );
    }

    /**
     * @notice function to handle Native bridging to receipent via Gnosis Native Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param metadata  socket offchain created hash
     * @param receiverAddress address of the token to bridged to the destination chain.
     * @param toChainId chainId of destination
     * @param amount amount to be bridged
     */
    function bridgeNativeTo(
        bytes32 metadata,
        address receiverAddress,
        uint256 toChainId,
        uint256 amount
    ) external payable {
        gnosisWethOmniBridgeHelper.wrapAndRelayTokens{value: amount}(
            receiverAddress
        );

        emit SocketBridge(
            amount,
            NATIVE_TOKEN_ADDRESS,
            toChainId,
            GnosisNativeBridgeIdentifier,
            msg.sender,
            receiverAddress,
            metadata
        );
    }

    /**
     * @notice function to bridge tokens after swap.
     * @notice this is different from swapAndBridge, this function is called when the swap has already happened at a different place.
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @dev for usage, refer to controller implementations
     *      encodedData for bridge should follow the sequence of properties in GnosisNativeBridgeData struct
     * @param amount amount of tokens being bridged. this can be ERC20 or native
     * @param bridgeData encoded data for Gnosis Native Bridge
     */
    function bridgeAfterSwap(
        uint256 amount,
        bytes calldata bridgeData
    ) external payable override {
        GnosisNativeBridgeData memory bridgeInfo = abi.decode(
            bridgeData,
            (GnosisNativeBridgeData)
        );

        // if from token is native ETH, use OmniBridge Weth helper contract
        // It wraps native ETH to WETH and bridges to to WETH on Gnosis
        if (bridgeInfo.fromTokenAddress == NATIVE_TOKEN_ADDRESS) {
            gnosisWethOmniBridgeHelper.wrapAndRelayTokens{value: amount}(
                bridgeInfo.receiverAddress
            );

            emit SocketBridge(
                amount,
                NATIVE_TOKEN_ADDRESS,
                bridgeInfo.toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                bridgeInfo.receiverAddress,
                bridgeInfo.metadata
            );
        }
        // if  from token is DAI on ethereum and toToken is xDai on Gnosis  use xdaiBridge
        else if (bridgeInfo.toTokenAddress == NATIVE_TOKEN_ADDRESS) {
            if (
                amount >
                ERC20(bridgeInfo.fromTokenAddress).allowance(
                    address(this),
                    address(gnosisXdaiBridge)
                )
            ) {
                ERC20(bridgeInfo.fromTokenAddress).safeApprove(
                    address(gnosisXdaiBridge),
                    UINT256_MAX
                );
            }

            gnosisXdaiBridge.relayTokens(bridgeInfo.receiverAddress, amount);

            emit SocketBridge(
                amount,
                bridgeInfo.fromTokenAddress,
                bridgeInfo.toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                bridgeInfo.receiverAddress,
                bridgeInfo.metadata
            );
        }
        // other ERC20 tokens use omni bridge
        else {
            if (
                amount >
                ERC20(bridgeInfo.fromTokenAddress).allowance(
                    address(this),
                    address(gnosisOmniBridge)
                )
            ) {
                ERC20(bridgeInfo.fromTokenAddress).safeApprove(
                    address(gnosisOmniBridge),
                    UINT256_MAX
                );
            }

            gnosisOmniBridge.relayTokens(
                bridgeInfo.fromTokenAddress,
                bridgeInfo.receiverAddress,
                amount
            );

            emit SocketBridge(
                amount,
                bridgeInfo.fromTokenAddress,
                bridgeInfo.toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                bridgeInfo.receiverAddress,
                bridgeInfo.metadata
            );
        }
    }

    /**
     * @notice function to bridge tokens after swap.
     * @notice this is different from bridgeAfterSwap since this function holds the logic for swapping tokens too.
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @dev for usage, refer to controller implementations
     *      encodedData for bridge should follow the sequence of properties in SymbiosisBridgeData struct
     * @param swapId routeId for the swapImpl
     * @param swapData encoded data for swap
     * @param metadata  socket offchain created hash
     * @param receiverAddress   address of the token to bridged to the destination chain.
     * @param toTokenAddress address of token being bridged
     * @param toChainId chainId of destination
     */
    function swapAndBridge(
        uint32 swapId,
        bytes calldata swapData,
        bytes32 metadata,
        address receiverAddress,
        address toTokenAddress,
        uint256 toChainId
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

        // if from token is native ETH, use OmniBridge Weth helper contract
        // It wraps native ETH to WETH and bridges to to WETH on Gnosis
        if (token == NATIVE_TOKEN_ADDRESS) {
            gnosisWethOmniBridgeHelper.wrapAndRelayTokens{value: bridgeAmount}(
                receiverAddress
            );

            emit SocketBridge(
                bridgeAmount,
                NATIVE_TOKEN_ADDRESS,
                toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                receiverAddress,
                metadata
            );
        }
        // if  from token is DAI on ethereum and toToken is xDai on Gnosis  use xdaiBridge
        else if (toTokenAddress == NATIVE_TOKEN_ADDRESS) {
            if (
                bridgeAmount >
                ERC20(token).allowance(address(this), address(gnosisXdaiBridge))
            ) {
                ERC20(token).safeApprove(
                    address(gnosisXdaiBridge),
                    UINT256_MAX
                );
            }

            gnosisXdaiBridge.relayTokens(receiverAddress, bridgeAmount);

            emit SocketBridge(
                bridgeAmount,
                token,
                toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                receiverAddress,
                metadata
            );
        }
        // other ERC20 tokens use omni bridge
        else {
            if (
                bridgeAmount >
                ERC20(token).allowance(address(this), address(gnosisOmniBridge))
            ) {
                ERC20(token).safeApprove(
                    address(gnosisOmniBridge),
                    UINT256_MAX
                );
            }

            gnosisOmniBridge.relayTokens(token, receiverAddress, bridgeAmount);

            emit SocketBridge(
                bridgeAmount,
                token,
                toChainId,
                GnosisNativeBridgeIdentifier,
                msg.sender,
                receiverAddress,
                metadata
            );
        }
    }
}
