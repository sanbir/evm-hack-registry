// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PRECISION, PERCENTAGE_100} from "@solarity/solidity-lib/utils/Globals.sol";

import {ISafe} from "../interfaces/ISafe.sol";
import {IAddressProvider} from "../interfaces/IAddressProvider.sol";
import {IDelegateBundler} from "../interfaces/IDelegateBundler.sol";
import {IPermissionsManager} from "../interfaces/IPermissionsManager.sol";
import {IWETH} from "../interfaces/IWETH.sol";

import {IBaseModule} from "../interfaces/modules/IBaseModule.sol";

import {Permissions} from "../libs/Permissions.sol";

abstract contract BaseModule is IBaseModule, ERC165 {
    uint256 public constant SLIPPAGE_PERCENTAGE = 5 * PRECISION;

    IPermissionsManager public immutable permissionsManager;
    IDelegateBundler public immutable delegateBundler;
    IWETH public immutable WETH;

    constructor(address addressProviderAddr) {
        IAddressProvider addressProvider = IAddressProvider(addressProviderAddr);

        permissionsManager = IPermissionsManager(addressProvider.getPermissionsManager());
        delegateBundler = IDelegateBundler(addressProvider.getDelegateBundler());
        WETH = IWETH(addressProvider.getWETH());
    }

    function getModuleName() public view virtual returns (string memory);

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IBaseModule).interfaceId || super.supportsInterface(interfaceId);
    }

    function _executeApproval(
        address safe,
        address token,
        address spender,
        uint256 amount
    ) internal virtual {
        address delegate = _getDelegate();

        _checkPermission(safe, delegate, Permissions.APPROVAL_PERMISSION);

        // Use safe approval in all cases
        _callApprove(safe, token, spender, 0);
        _callApprove(safe, token, spender, amount);

        emit PermissionedApprovalExecuted(safe, delegate, token, spender, amount);
    }

    function _executeWrapNative(address safe, uint256 amountToWrap) internal virtual {
        address delegate = _getDelegate();

        _checkPermission(safe, delegate, Permissions.WRAP_NATIVE_PERMISSION);

        bytes memory depositData = abi.encodeCall(IWETH.deposit, ());

        _safeCall(safe, address(WETH), amountToWrap, depositData, "wrap");

        emit NativeTokensWrapped(safe, delegate, amountToWrap);
    }

    function _executeUnwrapNative(address safe, uint256 amountToUnwrap) internal virtual {
        address delegate = _getDelegate();

        _checkPermission(safe, delegate, Permissions.UNWRAP_NATIVE_PERMISSION);

        bytes memory withdrawData = abi.encodeCall(IWETH.withdraw, (amountToUnwrap));

        _safeCall(safe, address(WETH), 0, withdrawData, "unwrap");

        emit NativeTokensUnwrapped(safe, delegate, amountToUnwrap);
    }

    function _safeCall(
        address safe,
        address to,
        uint256 value,
        bytes memory data,
        string memory callName
    ) internal {
        require(
            ISafe(safe).execTransactionFromModule(to, value, data, 0),
            CallExecutionFailed(callName)
        );
    }

    function _trySafeCall(
        address safe,
        address to,
        uint256 value,
        bytes memory data
    ) internal returns (bool) {
        return ISafe(safe).execTransactionFromModule(to, value, data, 0);
    }

    function _safeCallWithReturnData(
        address safe,
        address to,
        uint256 value,
        bytes memory data,
        string memory callName
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = ISafe(safe).execTransactionFromModuleReturnData(
            to,
            value,
            data,
            0
        );

        require(success, CallExecutionFailed(callName));

        return returnData;
    }

    function _callApprove(address safe, address token, address spender, uint256 amount) private {
        bytes memory approvalData = abi.encodeWithSignature(
            "approve(address,uint256)",
            spender,
            amount
        );

        _safeCall(safe, token, 0, approvalData, "approve");
    }

    function _checkPermission(
        address safe,
        address delegate,
        string memory permissionName
    ) internal view virtual {
        require(
            permissionsManager.hasPermission(safe, delegate, _getPermissionEntry(permissionName)),
            PermissionDenied(safe, delegate, permissionName)
        );
    }

    function _getDelegate() internal view returns (address) {
        return
            msg.sender == address(delegateBundler)
                ? delegateBundler.currentDelegate()
                : msg.sender;
    }

    function _getPermissionEntry(
        string memory permissionName
    ) internal view returns (IPermissionsManager.PermissionEntry memory) {
        return
            IPermissionsManager.PermissionEntry({
                moduleAddr: address(this),
                permission: permissionName
            });
    }

    function _isWETH(address token) internal view returns (bool) {
        return address(WETH) == token;
    }

    function _checkAmountSlippage(uint256 amountPassed, uint256 amountExpected) internal pure {
        uint256 expectedAmountWithSlippage = _applySlippage(amountExpected);

        require(
            amountPassed >= expectedAmountWithSlippage,
            InvalidAmountSlippage(amountPassed, expectedAmountWithSlippage)
        );
    }

    function _applySlippage(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, PERCENTAGE_100 - SLIPPAGE_PERCENTAGE, PERCENTAGE_100);
    }
}
