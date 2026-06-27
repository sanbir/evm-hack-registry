// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./interfaces/symbiosis.sol";
import "../BridgeImplBase.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ISymbiosisMetaRouter} from "./interfaces/symbiosis.sol";
import {SYMBIOSIS} from "../../static/RouteIdentifiers.sol";

/**
 * @title Symbiosis-Route Implementation
 * @notice Route implementation with functions to bridge ERC20 and Native via Symbiosis-Bridge
 * Called via SocketGateway if the routeId in the request maps to the routeId of SymbiosisImplementation
 * Contains function to handle bridging as post-step i.e linked to a preceeding step for swap
 * RequestData is different to just bride and bridging chained with swap
 * @author Socket dot tech.
 */
contract SymbiosisBridgeImpl is BridgeImplBase {
    /// @notice SafeTransferLib - library for safe and optimised operations on ERC20 tokens
    using SafeTransferLib for ERC20;

    bytes32 public immutable SymbiosisIdentifier = SYMBIOSIS;

    /// @notice max value for uint256
    uint256 public constant UINT256_MAX = type(uint256).max;

    /// @notice Function-selector for ERC20-token bridging on Symbiosis-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge ERC20 tokens
    bytes4 public immutable SYMBIOSIS_ERC20_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(
            keccak256(
                "bridgeERC20To(bytes32,address,address,uint256,(bytes,bytes,address[],address,address,uint256,bool,address,bytes))"
            )
        );

    /// @notice Function-selector for Native bridging on Symbiosis-Route
    /// @dev This function selector is to be used while buidling transaction-data to bridge Native tokens
    bytes4 public immutable SYMBIOSIS_NATIVE_EXTERNAL_BRIDGE_FUNCTION_SELECTOR =
        bytes4(
            keccak256(
                "bridgeNativeTo(bytes32,address,uint256,(bytes,bytes,address[],address,address,uint256,bool,address,bytes))"
            )
        );

    bytes4 public immutable SYMBIOSIS_SWAP_BRIDGE_SELECTOR =
        bytes4(
            keccak256(
                "swapAndBridge(uint32,bytes,bytes32,address,uint256,(bytes,bytes,address[],address,address,uint256,bool,address,bytes))"
            )
        );

    struct SymbiosisMetaRouteData {
        bytes firstSwapCalldata;
        bytes secondSwapCalldata;
        address[] approvedTokens;
        address firstDexRouter;
        address secondDexRouter;
        uint256 amount;
        bool nativeIn;
        address relayRecipient;
        bytes otherSideCalldata;
    }

    struct SymbiosisBridgeData {
        /// @notice address of token being bridged
        address token;
        /// @notice address of receiver
        address receiverAddress;
        /// @notice chainId of destination
        uint256 toChainId;
        /// @notice socket offchain created hash
        bytes32 metadata;
        /// @notice Struct representing a origin request for SymbiosisRouter
        SymbiosisMetaRouteData _symbiosisData;
    }

    /// @notice The contract address of the Symbiosis router on the source chain
    ISymbiosisMetaRouter private immutable symbiosisMetaRouter;
    address private immutable symbiosisGateway;

    /// @notice socketGatewayAddress to be initialised via storage variable BridgeImplBase
    /// @dev ensure liquidityPoolManager-address are set properly for the chainId in which the contract is being deployed
    constructor(
        address _symbiosisMetaRouter,
        address _symbiosisGateway,
        address _socketGateway,
        address _socketDeployFactory
    ) BridgeImplBase(_socketGateway, _socketDeployFactory) {
        symbiosisMetaRouter = ISymbiosisMetaRouter(_symbiosisMetaRouter);
        symbiosisGateway = _symbiosisGateway;
    }

    /**
     * @notice function to handle ERC20 bridging to receipent via Symbiosis-Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param receiverAddress address of the token to bridged to the destination chain.
     * @param token address of token being bridged
     * @param toChainId chainId of destination
     */
    function bridgeERC20To(
        bytes32 metadata,
        address receiverAddress,
        address token,
        uint256 toChainId,
        SymbiosisMetaRouteData calldata _symbiosisData
    ) external payable {
        ERC20(token).safeTransferFrom(
            msg.sender,
            socketGateway,
            _symbiosisData.amount
        );

        if (
            _symbiosisData.amount >
            ERC20(token).allowance(address(this), address(symbiosisGateway))
        ) {
            ERC20(token).safeApprove(address(symbiosisGateway), UINT256_MAX);
        }
        symbiosisMetaRouter.metaRoute(
            ISymbiosisMetaRouter.MetaRouteTransaction(
                _symbiosisData.firstSwapCalldata,
                _symbiosisData.secondSwapCalldata,
                _symbiosisData.approvedTokens,
                _symbiosisData.firstDexRouter,
                _symbiosisData.secondDexRouter,
                _symbiosisData.amount,
                _symbiosisData.nativeIn,
                _symbiosisData.relayRecipient,
                _symbiosisData.otherSideCalldata
            )
        );

        emit SocketBridge(
            _symbiosisData.amount,
            token,
            toChainId,
            SymbiosisIdentifier,
            msg.sender,
            receiverAddress,
            metadata
        );
    }

    /**
     * @notice function to handle Native bridging to receipent via Symbiosis-Bridge
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @param receiverAddress address of the token to bridged to the destination chain.
     * @param toChainId chainId of destination
     */
    function bridgeNativeTo(
        bytes32 metadata,
        address receiverAddress,
        uint256 toChainId,
        SymbiosisMetaRouteData calldata _symbiosisData
    ) external payable {
        symbiosisMetaRouter.metaRoute{value: _symbiosisData.amount}(
            ISymbiosisMetaRouter.MetaRouteTransaction(
                _symbiosisData.firstSwapCalldata,
                _symbiosisData.secondSwapCalldata,
                _symbiosisData.approvedTokens,
                _symbiosisData.firstDexRouter,
                _symbiosisData.secondDexRouter,
                _symbiosisData.amount,
                _symbiosisData.nativeIn,
                _symbiosisData.relayRecipient,
                _symbiosisData.otherSideCalldata
            )
        );

        emit SocketBridge(
            _symbiosisData.amount,
            NATIVE_TOKEN_ADDRESS,
            toChainId,
            SymbiosisIdentifier,
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
     *      encodedData for bridge should follow the sequence of properties in SymbiosisData struct
     * @param amount amount of tokens being bridged. this can be ERC20 or native
     * @param bridgeData encoded data for SymbiosisBridge
     */
    function bridgeAfterSwap(
        uint256 amount,
        bytes calldata bridgeData
    ) external payable override {
        SymbiosisBridgeData memory bridgeInfo = abi.decode(
            bridgeData,
            (SymbiosisBridgeData)
        );

        if (bridgeInfo.token == NATIVE_TOKEN_ADDRESS) {
            symbiosisMetaRouter.metaRoute{value: amount}(
                ISymbiosisMetaRouter.MetaRouteTransaction(
                    bridgeInfo._symbiosisData.firstSwapCalldata,
                    bridgeInfo._symbiosisData.secondSwapCalldata,
                    bridgeInfo._symbiosisData.approvedTokens,
                    bridgeInfo._symbiosisData.firstDexRouter,
                    bridgeInfo._symbiosisData.secondDexRouter,
                    amount,
                    bridgeInfo._symbiosisData.nativeIn,
                    bridgeInfo._symbiosisData.relayRecipient,
                    bridgeInfo._symbiosisData.otherSideCalldata
                )
            );
        } else {
            if (
                amount >
                ERC20(bridgeInfo.token).allowance(
                    address(this),
                    address(symbiosisGateway)
                )
            ) {
                ERC20(bridgeInfo.token).safeApprove(
                    address(symbiosisGateway),
                    UINT256_MAX
                );
            }

            symbiosisMetaRouter.metaRoute(
                ISymbiosisMetaRouter.MetaRouteTransaction(
                    bridgeInfo._symbiosisData.firstSwapCalldata,
                    bridgeInfo._symbiosisData.secondSwapCalldata,
                    bridgeInfo._symbiosisData.approvedTokens,
                    bridgeInfo._symbiosisData.firstDexRouter,
                    bridgeInfo._symbiosisData.secondDexRouter,
                    amount,
                    bridgeInfo._symbiosisData.nativeIn,
                    bridgeInfo._symbiosisData.relayRecipient,
                    bridgeInfo._symbiosisData.otherSideCalldata
                )
            );
        }

        emit SocketBridge(
            amount,
            bridgeInfo.token,
            bridgeInfo.toChainId,
            SymbiosisIdentifier,
            msg.sender,
            bridgeInfo.receiverAddress,
            bridgeInfo.metadata
        );
    }

    /**
     * @notice function to bridge tokens after swap.
     * @notice this is different from bridgeAfterSwap since this function holds the logic for swapping tokens too.
     * @notice This method is payable because the caller is doing token transfer and briding operation
     * @dev for usage, refer to controller implementations
     *      encodedData for bridge should follow the sequence of properties in SymbiosisBridgeData struct
     * @param swapId routeId for the swapImpl
     * @param swapData encoded data for swap
     * @param _symbiosisData encoded data for SymbiosisData
     */
    function swapAndBridge(
        uint32 swapId,
        bytes calldata swapData,
        bytes32 metadata,
        address receiverAddress,
        uint256 toChainId,
        SymbiosisMetaRouteData calldata _symbiosisData
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

        if (token == NATIVE_TOKEN_ADDRESS) {
            symbiosisMetaRouter.metaRoute{value: bridgeAmount}(
                ISymbiosisMetaRouter.MetaRouteTransaction(
                    _symbiosisData.firstSwapCalldata,
                    _symbiosisData.secondSwapCalldata,
                    _symbiosisData.approvedTokens,
                    _symbiosisData.firstDexRouter,
                    _symbiosisData.secondDexRouter,
                    bridgeAmount,
                    _symbiosisData.nativeIn,
                    _symbiosisData.relayRecipient,
                    _symbiosisData.otherSideCalldata
                )
            );
        } else {
            if (
                bridgeAmount >
                ERC20(token).allowance(address(this), address(symbiosisGateway))
            ) {
                ERC20(token).safeApprove(
                    address(symbiosisGateway),
                    UINT256_MAX
                );
            }

            symbiosisMetaRouter.metaRoute(
                ISymbiosisMetaRouter.MetaRouteTransaction(
                    _symbiosisData.firstSwapCalldata,
                    _symbiosisData.secondSwapCalldata,
                    _symbiosisData.approvedTokens,
                    _symbiosisData.firstDexRouter,
                    _symbiosisData.secondDexRouter,
                    bridgeAmount,
                    _symbiosisData.nativeIn,
                    _symbiosisData.relayRecipient,
                    _symbiosisData.otherSideCalldata
                )
            );
        }

        emit SocketBridge(
            bridgeAmount,
            token,
            toChainId,
            SymbiosisIdentifier,
            msg.sender,
            receiverAddress,
            metadata
        );
    }
}
