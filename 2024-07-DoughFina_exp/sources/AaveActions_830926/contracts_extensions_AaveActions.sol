// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IDoughIndex, CustomError } from "../Interfaces.sol";
import { DoughCore } from "../libraries/DoughCore.sol";

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
* @title AaveActions
* @notice This utility contract allows Loop, Deloop, Switch actions in Aave V3 for the DSA from the DoughIndex
* @custom:version 1.0 - Initial release
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
contract AaveActions {
    using SafeERC20 for IERC20;

    /* ========== LAYOUT ========== */
    address public dsaOwner;
    address public doughIndex;

    /**
     * @notice Initializes the ConnectorAaveActions contract
     * @param _doughIndex The address of the DoughIndex contract
     */
    constructor(address _doughIndex) {
        if (_doughIndex == address(0)) revert CustomError("DoughIndex address is 0");
        doughIndex = _doughIndex;
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
    function executeAaveAction(uint256 _connectorId, address _tokenIn, uint256 _inAmount, address _tokenOut, uint256 _outAmount, uint256 _actionId) external payable {
        address _connectorFlashloan = IDoughIndex(doughIndex).getDoughConnector(_connectorId);
        if(msg.sender != address(this) && msg.sender != _connectorFlashloan) revert CustomError("Actions caller not DSA");

        // Check if the DSA is registered in the DoughIndex
        if(msg.sender == address(this)) {
            if(IDoughIndex(doughIndex).getOwnerOfDoughDsa(address(this)) == address(0)) revert CustomError("DSA not found");
        }

        //  __actionId: 0-Loop , 1-DeLoop,  2-Switch
        if (_actionId > 2) revert CustomError("FlashloanReq: invalid-id");

        IERC20(_tokenIn).safeTransferFrom(_connectorFlashloan, address(this), _inAmount);
        IERC20(_tokenIn).safeIncreaseAllowance(DoughCore.AAVE_V3_POOL_ADDRESS, _inAmount);
        if (_actionId == 0) {
            // Loop
            DoughCore._I_AAVE_V3_POOL.supply(_tokenIn, _inAmount, address(this), 0);
            DoughCore._I_AAVE_V3_POOL.borrow(_tokenOut, _outAmount, DoughCore.VARIABLE_RATE_MODE, 0, address(this));
        } else if (_actionId == 1) {
            // Deloop
            if (_inAmount > 0) {
                DoughCore._I_AAVE_V3_POOL.repay(_tokenIn, _inAmount, DoughCore.VARIABLE_RATE_MODE, address(this));
            }
            if (_outAmount > 0) {
                DoughCore._I_AAVE_V3_POOL.withdraw(_tokenOut, _outAmount, address(this));
            }
        } else {
            // Switch
            DoughCore._I_AAVE_V3_POOL.supply(_tokenIn, _inAmount, address(this), 0);
            DoughCore._I_AAVE_V3_POOL.withdraw(_tokenOut, _outAmount, address(this));
        }
        IERC20(_tokenOut).safeIncreaseAllowance(_connectorFlashloan, _outAmount);
    }

    /**
     * @notice Function to set new dough index address after upgrade
     * @param _newDoughIndex The address of the new DoughIndex contract
     * @dev The new DoughIndex address should not be the zero address
     * @dev Only the multisig of DoughIndex can call this function
     */
    function setNewDoughIndex(address _newDoughIndex) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_newDoughIndex == address(0)) revert CustomError("invalid _newDoughIndex");
        doughIndex = _newDoughIndex;
    }

    /** @notice Function to get the Dough Multisig address */
    function getDoughMultisig() external view returns (address) {
        return IDoughIndex(doughIndex).multisig();
    }

    /** @notice Function to get the Dough Index address */
    function getDoughIndex() external view returns (address) {
        return doughIndex;
    }

    /**
    * @notice Function to withdraw accidentaly sent ETH/ERC20 tokens to the connector
    * @param _asset The address of the ETH/ERC20 token
    * @param _treasury The address of the treasury
    * @param _amount The amount of ETH/ERC20 token to withdraw
    */
    function withdrawToken(address _asset, address _treasury, uint256 _amount) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_treasury == address(0)) revert CustomError("invalid _treasury");
        if (_amount == 0) revert CustomError("must be greater than zero");
        if (_asset == DoughCore.ETH) {
            payable(_treasury).transfer(_amount);
        } else {
            uint256 balanceOfToken = IERC20(_asset).balanceOf(address(this));
            uint256 transferAmount = _amount;
            if (_amount > balanceOfToken) {
                transferAmount = balanceOfToken;
            }
            IERC20(_asset).safeTransfer(_treasury, transferAmount);
        }
    }

    // 30 more storage slots for future updates
    // uint256[30] __gap;
}