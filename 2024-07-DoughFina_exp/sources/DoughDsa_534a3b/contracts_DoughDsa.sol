// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.24;
import { IDoughIndex, CustomError } from "./Interfaces.sol";

/**
* $$$$$$$\                                $$\             $$$$$$$$\ $$\                                                   
* $$  __$$\                               $$ |            $$  _____|\__|                                                  
* $$ |  $$ | $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$$\        $$ |      $$\ $$$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
* $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$\       $$$$$\    $$ |$$  __$$\  \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
* $$ |  $$ |$$ /  $$ |$$ |  $$ |$$ /  $$ |$$ |  $$ |      $$  __|   $$ |$$ |  $$ | $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
* $$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |$$  __$$ |$$ |  $$ |$$ |      $$   ____|
* $$$$$$$  |\$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
* \_______/  \______/  \______/  \____$$ |\__|  \__|      \__|      \__|\__|  \__| \_______|\__|  \__| \_______| \_______|
*                               $$\   $$ |                                                                                
*                               \$$$$$$  |                                                                                
*                                \______/                                                                                 
* 
* @title DoughDsa
* @notice This contract is used to delegate the call to the respective connectors
* @custom:version 1.0 - Initial release
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
contract DoughDsa {
    /* ========== LAYOUT ========== */
    address public dsaOwner;
    address public doughIndex;

    /**
    * @notice Initializes the DoughDsa contract
    * @param _dsaOwner: The DSA owner address of the DSA contract
    * @param _doughIndex: The DoughIndex contract address
    */
    function initialize(address _dsaOwner, address _doughIndex) external {
        if (dsaOwner != address(0) || _dsaOwner == address(0)) revert CustomError("invalid dsaOwner");
        if (doughIndex != address(0) || _doughIndex == address(0)) revert CustomError("invalid doughIndex");
        doughIndex = _doughIndex;
        dsaOwner = _dsaOwner;
    }

    /**
    * @notice Delegates the call to the respective connector
    * @param _connectorId: The connector ID to call
    * @param _actionId: The action ID to call
    * @param _token: The token address to call
    * @param _amount: The amount to call
    * @param _opt: The optional boolean value
    * @param _swapData: The swap data to call
    */
    function doughCall(uint256 _connectorId, uint256 _actionId, address _token, uint256 _amount, bool _opt, bytes[] calldata _swapData) external payable {
        // _connectorId:  0-dsa  1-aave  2-paraswap  3-uniV3  4-deleveraging-uniV3  4-deleveraging-paraswap  5-shield  6-vault
        address _contract = IDoughIndex(doughIndex).getDoughConnector(_connectorId);
        if (_contract == address(0)) revert CustomError("Unregistered Connector");

        if (_connectorId < 21) {
            // only the DSA Owner can run supply, withdraw, repay, swap, loop, deloop, etc
            if (msg.sender != dsaOwner) revert CustomError("Caller not dsaOwner");
        } else if (_connectorId == 21 || _connectorId == 22) {
            if (msg.sender != IDoughIndex(doughIndex).deleverageAutomation()) revert CustomError("Only Deleveraging Automation");
        } else if (_connectorId == 23) {
            if (msg.sender != IDoughIndex(doughIndex).shieldAutomation()) revert CustomError("Only Shield Automation");
        } else if (_connectorId == 24) {
            if (msg.sender != IDoughIndex(doughIndex).vaultAutomation()) revert CustomError("Only Vault Automation");
        } else {
            // future connectors will only be available to the DSA Owner
            if (msg.sender != dsaOwner) revert CustomError("Caller not dsaOwner");
        }

        (bool success, bytes memory data) = _contract.delegatecall(abi.encodeWithSignature("delegateDoughCall(uint256,address,uint256,bool,bytes[])", _actionId, _token, _amount, _opt, _swapData));
        if (!success) {
            if (data.length == 0) revert CustomError("Invalid doughcall error length");
            if (data.length > 0) {
                assembly {
                    revert(add(32, data), mload(data))
                }
            }
        }

    }

    /**
    * @notice Executes an action from and to the Flashloan Connector
    * @param _connectorId: The connector ID
    * @param _tokenIn: The token address to get in
    * @param _inAmount: The amount to get in
    * @param _tokenOut: The token address to get out
    * @param _outAmount: The amount to get out
    * @param _actionId: The action ID to call
    */
    function executeAction(uint256 _connectorId, address _tokenIn, uint256 _inAmount, address _tokenOut, uint256 _outAmount, uint256 _actionId) external payable {
        address _connector = IDoughIndex(doughIndex).getDoughConnector(_connectorId);
        if(msg.sender != address(this) && msg.sender != _connector) revert CustomError("Caller not owner or DSA");

        address aaveActions = IDoughIndex(doughIndex).aaveActionsAddress();

        (bool success, bytes memory data) = aaveActions.delegatecall(abi.encodeWithSignature("executeAaveAction(uint256,address,uint256,address,uint256,uint256)", _connectorId, _tokenIn, _inAmount, _tokenOut, _outAmount, _actionId));
        if (!success) {
            if (data.length == 0) revert CustomError("Invalid Aave error length");
            if (data.length > 0) {
                assembly {
                    revert(add(32, data), mload(data))
                }
            }
        }

    }

    /**
    * @notice allows DSA Owner to deposit and withdraw ETH
    */
    receive() external payable {}
    fallback() external payable {}
}