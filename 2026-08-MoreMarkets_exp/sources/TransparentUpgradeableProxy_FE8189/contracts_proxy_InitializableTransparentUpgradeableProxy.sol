// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
// import "./InitializableERC1967Proxy.sol";

// contract InceptionProxyAdmin is ProxyAdmin {}

// /// @dev The original OpenZeppelin Contracts (last updated v4.9.0) (proxy/transparent/TransparentUpgradeableProxy.sol)
// /// with replacement constructor by initializer
// contract InitializableTransparentUpgradeableProxy is InitializableERC1967Proxy {
//     /**
//      * Contract initializer.
//      * @param _logic address of the initial implementation.
//      * @param admin_ Address of the proxy administrator.
//      * @param _data Data to send as msg.data to the implementation to initialize the proxied contract
//      */
//     function initialize(
//         address _logic,
//         address admin_,
//         bytes memory _data
//     ) external payable {
//         require(
//             _implementation() == address(0),
//             "implementation has already been set"
//         );
//         _upgradeToAndCall(_logic, _data, false);
//         _changeAdmin(admin_);
//     }

//     /**
//      * @dev Modifier used internally that will delegate the call to the implementation unless the sender is the admin.
//      *
//      * CAUTION: This modifier is deprecated, as it could cause issues if the modified function has arguments, and the
//      * implementation provides a function with the same selector.
//      */
//     modifier ifAdmin() {
//         if (msg.sender == _getAdmin()) {
//             _;
//         } else {
//             _fallback();
//         }
//     }

//     /**
//      * @dev If caller is the admin process the call internally, otherwise transparently fallback to the proxy behavior
//      */
//     function _fallback() internal virtual override {
//         if (msg.sender == _getAdmin()) {
//             bytes memory ret;
//             bytes4 selector = msg.sig;
//             if (selector == ITransparentUpgradeableProxy.upgradeTo.selector) {
//                 ret = _dispatchUpgradeTo();
//             } else if (
//                 selector ==
//                 ITransparentUpgradeableProxy.upgradeToAndCall.selector
//             ) {
//                 ret = _dispatchUpgradeToAndCall();
//             } else if (
//                 selector == ITransparentUpgradeableProxy.changeAdmin.selector
//             ) {
//                 ret = _dispatchChangeAdmin();
//             } else if (
//                 selector == ITransparentUpgradeableProxy.admin.selector
//             ) {
//                 ret = _dispatchAdmin();
//             } else if (
//                 selector == ITransparentUpgradeableProxy.implementation.selector
//             ) {
//                 ret = _dispatchImplementation();
//             } else {
//                 revert(
//                     "TransparentUpgradeableProxy: admin cannot fallback to proxy target"
//                 );
//             }
//             assembly {
//                 return(add(ret, 0x20), mload(ret))
//             }
//         } else {
//             super._fallback();
//         }
//     }

//     /**
//      * @dev Returns the current admin.
//      *
//      * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using the
//      * https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
//      * `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
//      */
//     function _dispatchAdmin() private returns (bytes memory) {
//         _requireZeroValue();

//         address admin = _getAdmin();
//         return abi.encode(admin);
//     }

//     /**
//      * @dev Returns the current implementation.
//      *
//      * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using the
//      * https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
//      * `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`
//      */
//     function _dispatchImplementation() private returns (bytes memory) {
//         _requireZeroValue();

//         address implementation = _implementation();
//         return abi.encode(implementation);
//     }

//     /**
//      * @dev Changes the admin of the proxy.
//      *
//      * Emits an {AdminChanged} event.
//      */
//     function _dispatchChangeAdmin() private returns (bytes memory) {
//         _requireZeroValue();

//         address newAdmin = abi.decode(msg.data[4:], (address));
//         _changeAdmin(newAdmin);

//         return "";
//     }

//     /**
//      * @dev Upgrade the implementation of the proxy.
//      */
//     function _dispatchUpgradeTo() private returns (bytes memory) {
//         _requireZeroValue();

//         address newImplementation = abi.decode(msg.data[4:], (address));
//         _upgradeToAndCall(newImplementation, bytes(""), false);

//         return "";
//     }

//     /**
//      * @dev Upgrade the implementation of the proxy, and then call a function from the new implementation as specified
//      * by `data`, which should be an encoded function call. This is useful to initialize new storage variables in the
//      * proxied contract.
//      */
//     function _dispatchUpgradeToAndCall() private returns (bytes memory) {
//         (address newImplementation, bytes memory data) = abi.decode(
//             msg.data[4:],
//             (address, bytes)
//         );
//         _upgradeToAndCall(newImplementation, data, true);

//         return "";
//     }

//     /**
//      * @dev Returns the current admin.
//      *
//      * CAUTION: This function is deprecated. Use {ERC1967Upgrade-_getAdmin} instead.
//      */
//     function _admin() internal view virtual returns (address) {
//         return _getAdmin();
//     }

//     /**
//      * @dev To keep this contract fully transparent, all `ifAdmin` functions must be payable. This helper is here to
//      * emulate some proxy functions being non-payable while still allowing value to pass through.
//      */
//     function _requireZeroValue() private {
//         require(msg.value == 0, "zero value is required");
//     }
// }
