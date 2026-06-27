// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {AxelarExpressExecutableWithToken} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/express/AxelarExpressExecutableWithToken.sol";
import {IAxelarGatewayWithToken} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGatewayWithToken.sol";

import {IBaseModule} from "../interfaces/modules/IBaseModule.sol";
import {ISquidRouterModule} from "../interfaces/modules/ISquidRouterModule.sol";

import {ISquidRouter} from "../interfaces/squid/ISquidRouter.sol";
import {IUniversalRouter} from "../interfaces/uniswap/IUniversalRouter.sol";
import {IPermit2} from "../interfaces/uniswap/IPermit2.sol";
import {IWETH} from "../interfaces/IWETH.sol";

import {Permissions} from "../libs/Permissions.sol";
import {UniversalRouterCommands} from "../libs/uniswap/UniversalRouterCommands.sol";

import {BaseModule} from "./BaseModule.sol";

contract SquidRouterModule is ISquidRouterModule, BaseModule, AxelarExpressExecutableWithToken {
    using SafeERC20 for IERC20;
    using Strings for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public immutable squidRouter;
    address public immutable permit2;

    EnumerableSet.AddressSet internal _universalRouters;

    constructor(
        address addressProvider,
        address squidRouterAddr,
        address axelarGatewayAddr,
        address permit2Addr,
        address[] memory universalRoutersArr
    ) BaseModule(addressProvider) AxelarExpressExecutableWithToken(axelarGatewayAddr) {
        squidRouter = squidRouterAddr;
        permit2 = permit2Addr;

        for (uint256 i = 0; i < universalRoutersArr.length; ++i) {
            _universalRouters.add(universalRoutersArr[i]);
        }
    }

    /// @inheritdoc ISquidRouterModule
    function executeSameChainActions(
        address safe,
        ActionsExecutionParams calldata params
    ) external {
        _executeSameChainActions(safe, params);
    }

    /// @inheritdoc ISquidRouterModule
    function executeSquidRouterBridgeWithActions(
        address safe,
        BridgeTokensParams calldata params
    ) external {
        _squidRouterBridgeTokens(safe, params);
    }

    /// @inheritdoc ISquidRouterModule
    function getSupportedUniversalRouters() public view returns (address[] memory) {
        return _universalRouters.values();
    }

    /// @inheritdoc ISquidRouterModule
    function isUniversalRouter(address router) public view returns (bool) {
        return _universalRouters.contains(router);
    }

    /// @inheritdoc IBaseModule
    function getModuleName()
        public
        pure
        override(BaseModule, IBaseModule)
        returns (string memory)
    {
        return "SquidRouterModule";
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ISquidRouterModule).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _executeSameChainActions(
        address safe,
        ActionsExecutionParams calldata params
    ) internal {
        address delegate = _getDelegate();

        _handleActions(safe, delegate, params);
    }

    function _squidRouterBridgeTokens(address safe, BridgeTokensParams calldata params) internal {
        address delegate = _getDelegate();

        _checkPermission(safe, delegate, Permissions.BRIDGE_DEPOSIT_PERMISSION);

        _handleActions(safe, delegate, params.sourceChainActionParams);

        bytes memory payload = abi.encode(address(this), safe, delegate, params.destinationChainActionParams);
        bytes memory bridgeTokensData = abi.encodeCall(
            ISquidRouter.bridgeCall,
            (
                params.bridgedTokenSymbol,
                params.amount,
                params.destinationChain,
                address(this).toHexString(),
                payload,
                safe,
                params.enableExpress
            )
        );

        _safeCall(safe, squidRouter, params.gasFeeAmount, bridgeTokensData, "bridgeTokens");

        emit SquidRouterBridgeTokensExecuted(
            safe,
            delegate,
            params.bridgedTokenSymbol,
            params.amount,
            params.destinationChain
        );
    }

    function _execute(
        bytes32,
        string calldata,
        string calldata,
        bytes calldata
    ) internal override {
        revert("Unsupported operation");
    }

    function _executeWithToken(
        bytes32,
        string calldata,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal override {
        // Verify source chain sender address
        address srcAddress = Strings.parseAddress(sourceAddress);
        require(srcAddress == squidRouter, InvalidSourceAddress(srcAddress));

        IERC20 token = IERC20(_getTokenAddress(tokenSymbol));

        _processPayload(token, amount, payload);
    }

    function _processPayload(
        IERC20 bridgedToken,
        uint256 bridgedTokenAmount,
        bytes calldata payload
    ) internal {
        (address module, address safe, address delegate, ActionsExecutionParams memory params) = abi.decode(
            payload,
            (address, address, address, ActionsExecutionParams)
        );

        require(module == address(this), InvalidModuleAddress(module));

        // Send all bridged tokens to the safe
        bridgedToken.safeTransfer(safe, bridgedTokenAmount);

        _handleActions(safe, delegate, params);
    }

    function _handleActions(
        address safe,
        address delegate,
        ActionsExecutionParams memory params
    ) internal {
        for (uint256 i = 0; i < params.actions.length; ++i) {
            if (!_handleAction(safe, delegate, params.actions[i])) {
                require(!params.isStrict, FailedToExecuteAction(i, params.actions[i].actionType));

                emit ActionExecutionFailed(safe, delegate, i, params.actions[i].actionType);

                break;
            } else {
                emit ActionExecuted(safe, delegate, i, params.actions[i].actionType);
            }
        }
    }

    function _handleAction(
        address safe,
        address delegate,
        ExecuteAction memory action
    ) internal returns (bool result) {
        if (action.actionType == ExecuteActionType.UNI_V3_SWAP_EXACT_IN) {
            result = _handleUniV3SwapExactIn(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.UNI_V3_SWAP_EXACT_OUT) {
            result = _handleUniV3SwapExactOut(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.UNI_V2_SWAP_EXACT_IN) {
            result = _handleUniV2SwapExactIn(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.UNI_V2_SWAP_EXACT_OUT) {
            result = _handleUniV2SwapExactOut(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.ERC20_APPROVE) {
            result = _handleERC20Approve(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.PERMIT2_APPROVE) {
            result = _handlePermit2Approve(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.NATIVE_WRAP) {
            result = _handleNativeWrap(safe, delegate, action.encodedData);
        } else if (action.actionType == ExecuteActionType.NATIVE_UNWRAP) {
            result = _handleNativeUnwrap(safe, delegate, action.encodedData);
        } else {
            return false;
        }
    }

    function _handleUniV3SwapExactIn(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool result) {
        _checkPermission(safe, delegate, Permissions.SWAP_PERMISSION);

        (
            address universalRouter,
            uint256 amountIn,
            uint256 amountOutMin,
            uint256 deadline,
            bytes memory path
        ) = abi.decode(encodedData, (address, uint256, uint256, uint256, bytes));

        if (!isUniversalRouter(universalRouter)) {
            return false;
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(safe, amountIn, amountOutMin, path, true);
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(UniversalRouterCommands.V3_SWAP_EXACT_IN))
        );

        bytes memory swapData = abi.encodeCall(
            IUniversalRouter.execute,
            (commands, inputs, deadline)
        );

        result = _trySafeCall(safe, universalRouter, 0, swapData);
    }

    function _handleUniV3SwapExactOut(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool result) {
        _checkPermission(safe, delegate, Permissions.SWAP_PERMISSION);

        (
            address universalRouter,
            uint256 amountOut,
            uint256 amountInMax,
            uint256 deadline,
            bytes memory path
        ) = abi.decode(encodedData, (address, uint256, uint256, uint256, bytes));

        if (!isUniversalRouter(universalRouter)) {
            return false;
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(safe, amountOut, amountInMax, path, true);
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(UniversalRouterCommands.V3_SWAP_EXACT_OUT))
        );

        bytes memory swapData = abi.encodeCall(
            IUniversalRouter.execute,
            (commands, inputs, deadline)
        );

        result = _trySafeCall(safe, universalRouter, 0, swapData);
    }

    function _handleUniV2SwapExactIn(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool result) {
        _checkPermission(safe, delegate, Permissions.SWAP_PERMISSION);

        (
            address universalRouter,
            uint256 amountIn,
            uint256 amountOutMin,
            uint256 deadline,
            bytes memory path
        ) = abi.decode(encodedData, (address, uint256, uint256, uint256, bytes));

        if (!isUniversalRouter(universalRouter)) {
            return false;
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(safe, amountIn, amountOutMin, path, true);
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(UniversalRouterCommands.V2_SWAP_EXACT_IN))
        );

        bytes memory swapData = abi.encodeCall(
            IUniversalRouter.execute,
            (commands, inputs, deadline)
        );

        result = _trySafeCall(safe, universalRouter, 0, swapData);
    }

    function _handleUniV2SwapExactOut(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool result) {
        _checkPermission(safe, delegate, Permissions.SWAP_PERMISSION);

        (
            address universalRouter,
            uint256 amountOut,
            uint256 amountInMax,
            uint256 deadline,
            bytes memory path
        ) = abi.decode(encodedData, (address, uint256, uint256, uint256, bytes));

        if (!isUniversalRouter(universalRouter)) {
            return false;
        }

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(safe, amountOut, amountInMax, path, true);
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(UniversalRouterCommands.V2_SWAP_EXACT_OUT))
        );

        bytes memory swapData = abi.encodeCall(
            IUniversalRouter.execute,
            (commands, inputs, deadline)
        );

        result = _trySafeCall(safe, universalRouter, 0, swapData);
    }

    function _handleERC20Approve(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool) {
        _checkPermission(safe, delegate, Permissions.APPROVAL_PERMISSION);

        (address token, address spender, uint256 amount) = abi.decode(
            encodedData,
            (address, address, uint256)
        );

        require(
            spender == squidRouter || isUniversalRouter(spender) || spender == permit2,
            InvalidSpender(spender)
        );

        // Use safe approval in all cases
        if (!_tryCallApprove(safe, token, spender, 0)) {
            return false;
        }
        if (!_tryCallApprove(safe, token, spender, amount)) {
            return false;
        }

        return true;
    }

    function _handlePermit2Approve(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool) {
        _checkPermission(safe, delegate, Permissions.APPROVAL_PERMISSION);

        (address token, address spender, uint160 amount) = abi.decode(
            encodedData,
            (address, address, uint160)
        );

        require(spender == squidRouter || isUniversalRouter(spender), InvalidSpender(spender));

        return _tryCallPermit2Approve(safe, token, spender, amount);
    }

    function _handleNativeWrap(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool) {
        _checkPermission(safe, delegate, Permissions.WRAP_NATIVE_PERMISSION);

        uint256 amount = abi.decode(encodedData, (uint256));

        bytes memory depositData = abi.encodeCall(IWETH.deposit, ());

        return _trySafeCall(safe, address(WETH), amount, depositData);
    }

    function _handleNativeUnwrap(
        address safe,
        address delegate,
        bytes memory encodedData
    ) internal returns (bool) {
        _checkPermission(safe, delegate, Permissions.UNWRAP_NATIVE_PERMISSION);

        uint256 amount = abi.decode(encodedData, (uint256));

        bytes memory withdrawData = abi.encodeCall(IWETH.withdraw, (amount));

        return _trySafeCall(safe, address(WETH), 0, withdrawData);
    }

    function _getTokenAddress(string calldata tokenSymbol) internal view returns (address) {
        return IAxelarGatewayWithToken(gatewayAddress).tokenAddresses(tokenSymbol);
    }

    function _tryCallApprove(
        address safe,
        address token,
        address spender,
        uint256 amount
    ) private returns (bool) {
        bytes memory approvalData = abi.encodeWithSignature(
            "approve(address,uint256)",
            spender,
            amount
        );

        return _trySafeCall(safe, token, 0, approvalData);
    }

    function _tryCallPermit2Approve(
        address safe,
        address token,
        address spender,
        uint160 amount
    ) internal returns (bool) {
        bytes memory permit2ApprovalData = abi.encodeCall(
            IPermit2.approve,
            (token, spender, amount, type(uint48).max)
        );

        return _trySafeCall(safe, permit2, 0, permit2ApprovalData);
    }
}
