// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {TTSwapError} from "./libraries/L_Error.sol";
import {L_UserConfigLibrary} from "./libraries/L_UserConfig.sol";
import {toTTSwapUINT256} from "./libraries/L_TTSwapUINT256.sol";
import {I_TTSwap_Token} from "./interfaces/I_TTSwap_Token.sol";
/**
 * @title TTSwap Market Proxy
 * @dev Proxy contract for TTSwap Market using delegatecall.
 * @notice This contract holds the storage and delegates logic execution to the implementation contract.
 * It supports upgradability controlled by admins.
 */
contract TTSwap_Market_Proxy {
    using L_UserConfigLibrary for uint256;
    address public implementation;
    I_TTSwap_Token public immutable TTS_CONTRACT;
    mapping(address _trader => uint256 nonce) private nonces;
    bool public upgradeable;

    /// @notice Initializes the proxy with the token contract and initial implementation.
    /// @param _TTS_Contract The address of the TTSwap Token contract (for permission checks).
    /// @param _implementation The address of the initial Market implementation logic.
    constructor(
        I_TTSwap_Token _TTS_Contract,
        address _implementation
    ) {
        TTS_CONTRACT = _TTS_Contract;
        implementation = _implementation;
        upgradeable = true;
    }

    /// @notice Fallback function that delegates calls to the implementation contract.
    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(result) {
                revert(0, returndatasize())
            } 
            return(0, returndatasize())
        }
    }

    /// @dev Restricts access to Market Admins.
    modifier onlyMarketAdminProxy() {
        if (!TTS_CONTRACT.userConfig(msg.sender).isMarketAdmin() || !upgradeable)
            revert TTSwapError(1);
        _;
    }

    /// @dev Restricts access to Market Managers.
    modifier onlyMarketManagerProxy() {
        if (!TTS_CONTRACT.userConfig(msg.sender).isMarketManager() || !upgradeable)
            revert TTSwapError(1);
        _;
    }

    /// @notice Upgrades the market implementation contract.
    /// @param _implementation The new implementation address.
    function upgrade(address _implementation) external onlyMarketAdminProxy {
        implementation = _implementation;
    }

    /// @notice Permanently disables upgradability.
    /// @dev Can only be called by DAO Admin. Once disabled, the implementation cannot be changed.
    function disableUpgrade() external {
        if (!TTS_CONTRACT.userConfig(msg.sender).isDAOAdmin()) revert TTSwapError(62);
        upgradeable = false;
    }

    /// @notice Freezes the market by setting implementation to address(0).
    /// @dev Can be called by Market Manager for emergency stops.
    function freezeMarket() external onlyMarketManagerProxy {
        implementation = address(0);
    }

    receive() external payable {}
}
