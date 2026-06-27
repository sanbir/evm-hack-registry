pragma solidity 0.8.20;

/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SharwaFinance
 * Copyright (C) 2025 SharwaFinance
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 **/

import {IModularSwapRouter} from "./interfaces/modularSwapRouter/IModularSwapRouter.sol";
import {IMarginAccount} from "./interfaces/IMarginAccount.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MarginAccount
 * @dev This contract manages the storage of margin accounts, including ERC20 and ERC721 tokens.
 * It also handles interactions with liquidity pools and a modular swap router.
 * @author 0nika0
 */
contract MarginAccount is IMarginAccount, AccessControl {
    bytes32 public constant MARGIN_TRADING_ROLE = keccak256("MARGIN_TRADING_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint private constant COEFFICIENT_DECIMALS = 1e5;
    uint private constant TIMELOCK = 7 days;

    mapping(uint => mapping(address => uint)) private erc20ByContract;
    mapping(uint => mapping(address => uint[])) private erc721ByContract;

    mapping(address => bool) public isAvailableErc20;
    mapping(address => bool) public isAvailableErc721;

    address[] public availableErc20;
    address[] public availableErc721;

    mapping(address => address) public tokenToLiquidityPool;

    address[] public availableTokenToLiquidityPool;

    IModularSwapRouter public modularSwapRouter;
    address public insurancePool;

    uint public erc721Limit = 10;
    uint public timelock = 0;
    uint public liquidatorFee = 0;

    constructor(
        address _insurancePool
    ) {
        insurancePool = _insurancePool;
        timelock = block.timestamp - 10;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier notLocked() {
        require(timelock != 0 && timelock <= block.timestamp, "Function is timelocked");
        _;
    }

    // VIEW FUNCTIONS //

    function getAvailableErc20() public view returns (address[] memory tokensArray) {
        return availableErc20;
    }

    function getAvailableErc721() public view returns (address[] memory tokensArray) {
        return availableErc721;
    }

    function getAvailableTokenToLiquidityPool() public view returns (address[] memory tokensArray) {
        return availableTokenToLiquidityPool;
    }

    function getErc20ByContract(uint marginAccountID, address tokenAddress) public view returns (uint) {
        return erc20ByContract[marginAccountID][tokenAddress];
    }

    function getErc721ByContract(uint marginAccountID, address tokenAddress) public view returns (uint[] memory) {
        return erc721ByContract[marginAccountID][tokenAddress];
    }

    function checkERC721tokenID(uint marginAccountID, address token, uint value) public view returns(bool hasERC721Id) {
        uint[] memory userERC721 = new uint[](erc721ByContract[marginAccountID][token].length);
        userERC721 = erc721ByContract[marginAccountID][token];
        for (uint i; i < userERC721.length; i++) {
            if (userERC721[i] == value) {
                return true;
            }
        } 
    }

    function checkERC20Amount(uint marginAccountID, address token, uint amount) external view returns(bool currectBalance) {
        currectBalance = amount <= erc20ByContract[marginAccountID][token];
    }

    function checkERC721Value(uint marginAccountID, address token, uint value) external view returns (bool hasERC721Id) {
        hasERC721Id = checkERC721tokenID(marginAccountID, token, value);
    }

    function checkLiquidityPool(address token) external view returns (bool isValid) {
        address liquidityPoolAddress = tokenToLiquidityPool[token];
        isValid = liquidityPoolAddress != address(0);       
    }

    // ONLY MANAGER_ROLE FUNCTIONS //

    function unlockFunction() external onlyRole(MANAGER_ROLE) {
        timelock = block.timestamp + TIMELOCK;
        emit Unlock(timelock);  
    }

    function lockFunction() external onlyRole(MANAGER_ROLE) {
        timelock = 0;
        emit Lock();
    }

    function setModularSwapRouter(IModularSwapRouter newModularSwapRouter) external onlyRole(MANAGER_ROLE) notLocked() {
        modularSwapRouter = newModularSwapRouter;

        emit UpdateModularSwapRouter(address(newModularSwapRouter));
    }

    function setTokenToLiquidityPool(address token, address liquidityPoolAddress) external onlyRole(MANAGER_ROLE) notLocked() {
        tokenToLiquidityPool[token] = liquidityPoolAddress;

        emit UpdateTokenToLiquidityPool(token, liquidityPoolAddress);
    }

    function setAvailableTokenToLiquidityPool(address[] memory _availableTokenToLiquidityPool) external onlyRole(MANAGER_ROLE) notLocked() {
        availableTokenToLiquidityPool = _availableTokenToLiquidityPool;

        emit UpdateAvailableTokenToLiquidityPool(_availableTokenToLiquidityPool);
    }

    function setAvailableErc20(address[] memory _availableErc20) external onlyRole(MANAGER_ROLE) notLocked() {
        availableErc20 = _availableErc20;

        emit UpdateAvailableErc20(_availableErc20);
    }

    function setIsAvailableErc20(address token, bool value) external onlyRole(MANAGER_ROLE) notLocked() {
        isAvailableErc20[token] = value;

        emit UpdateIsAvailableErc20(token, value);
    }
    
    function setAvailableErc721(address[] memory _availableErc721) external onlyRole(MANAGER_ROLE) notLocked() {
        availableErc721 = _availableErc721;

        emit UpdateAvailableErc721(availableErc721);
    }

    function setIsAvailableErc721(address token, bool value) external onlyRole(MANAGER_ROLE) notLocked() {
        isAvailableErc721[token] = value;

        emit UpdateIsAvailableErc721(token, value);
    }    

    function setErc721Limit(uint newErc721Limit) external onlyRole(MANAGER_ROLE) {
        erc721Limit = newErc721Limit;

        emit UpdateErc721Limit(newErc721Limit);
    }   

    function setLiquidatorFee(uint newLiquidatorFee) external onlyRole(MANAGER_ROLE) {
        liquidatorFee = newLiquidatorFee;

        emit UpdateLiquidatorFee(newLiquidatorFee);
    }   

    function approveERC20(address token, address to, uint amount) external onlyRole(MANAGER_ROLE) {
        IERC20(token).approve(to, amount);
    }

    function approveERC721ForAll(address token, address to, bool value) external onlyRole(MANAGER_ROLE) {
        IERC721(token).setApprovalForAll(to, value);
    }

    // ONLY MARGIN_TRADING_ROLE FUNCTIONS //

    function provideERC20(uint marginAccountID, address txSender, address token, uint amount) external onlyRole(MARGIN_TRADING_ROLE) {
        require(isAvailableErc20[token], "Token you are attempting to deposit is not available for deposit");
        erc20ByContract[marginAccountID][token] += amount;
        IERC20(token).transferFrom(txSender, address(this), amount);
    }

    function provideERC721(uint marginAccountID, address txSender, address baseToken, address token, uint collateralTokenID) external onlyRole(MARGIN_TRADING_ROLE) {
        require(isAvailableErc721[token], "Token you are attempting to deposit is not available for deposit");
        require(erc721ByContract[marginAccountID][token].length <= erc721Limit, "erc721limit is exceeded");
        erc721ByContract[marginAccountID][token].push(collateralTokenID);
        IERC721(token).transferFrom(txSender, address(this), collateralTokenID);
    }

    function withdrawERC20(uint marginAccountID, address token, uint amount, address txSender) external onlyRole(MARGIN_TRADING_ROLE) {
        erc20ByContract[marginAccountID][token] -= amount;
        IERC20(token).transfer(txSender, amount);
    }

    function withdrawERC721(uint marginAccountID, address token, uint value, address txSender) external onlyRole(MARGIN_TRADING_ROLE) {
        _deleteERC721TokenFromContractList(marginAccountID, token, value);
        IERC721(token).safeTransferFrom(address(this), txSender, value);
    }

    function borrow(uint marginAccountID, address token, uint amount) external onlyRole(MARGIN_TRADING_ROLE) {
        require(isAvailableErc20[token], "Token you are attempting to deposit is not available for deposit");
        address liquidityPoolAddress = tokenToLiquidityPool[token];       
        require(liquidityPoolAddress != address(0), "Token is not supported");

        erc20ByContract[marginAccountID][token] += amount;
        ILiquidityPool(liquidityPoolAddress).borrow(marginAccountID, amount);
    }

    function repay(uint marginAccountID, address token, uint amount) external onlyRole(MARGIN_TRADING_ROLE) {
        address liquidityPoolAddress = tokenToLiquidityPool[token];    
        require(liquidityPoolAddress != address(0), "Token is not supported");

        uint debtWithAccruedInterest = ILiquidityPool(liquidityPoolAddress).getDebtWithAccruedInterest(marginAccountID);
        if (amount == 0 || amount > debtWithAccruedInterest) {
            amount = debtWithAccruedInterest;
        }

        require(amount <= erc20ByContract[marginAccountID][token], "Insufficient funds to repay the debt");
        
        erc20ByContract[marginAccountID][token] -= amount;
        ILiquidityPool(liquidityPoolAddress).repay(marginAccountID, amount);
    }

    function liquidate(uint marginAccountID, address baseToken, address marginAccountOwner, address liquidator) external onlyRole(MARGIN_TRADING_ROLE) {
        IModularSwapRouter.ERC20PositionInfo[] memory erc20Params = new IModularSwapRouter.ERC20PositionInfo[](availableErc20.length); 
        IModularSwapRouter.ERC721PositionInfo[] memory erc721Params = new IModularSwapRouter.ERC721PositionInfo[](availableErc721.length);

        for(uint i; i < availableErc20.length; i++) {
            uint erc20Balance = erc20ByContract[marginAccountID][availableErc20[i]];
            erc20Params[i] = IModularSwapRouter.ERC20PositionInfo(availableErc20[i], baseToken, erc20Balance);
            erc20ByContract[marginAccountID][availableErc20[i]] -= erc20Balance;
        }

        for(uint i; i < availableErc721.length; i++) {
            uint[] memory erc721TokensByContract = erc721ByContract[marginAccountID][availableErc721[i]];
            erc721Params[i] = IModularSwapRouter.ERC721PositionInfo(availableErc721[i], baseToken, marginAccountOwner, erc721TokensByContract);
            delete erc721ByContract[marginAccountID][availableErc721[i]];
        }

        uint amountOutInUSDC = modularSwapRouter.liquidate(marginAccountID, erc20Params,erc721Params);

        erc20ByContract[marginAccountID][baseToken] += amountOutInUSDC;

        _clearDebtsWithPools(marginAccountID, baseToken, liquidator);
    }

    function swap(uint marginAccountID, uint swapID, address tokenIn, address tokenOut, uint amountIn, uint amountOutMinimum) external onlyRole(MARGIN_TRADING_ROLE){
        require(isAvailableErc20[tokenIn] && isAvailableErc20[tokenOut], "Token is not available");
        require(amountIn <= erc20ByContract[marginAccountID][tokenIn], "Insufficient funds for the swap");
        uint amountOut = modularSwapRouter.swapInput(tokenIn, tokenOut, amountIn, amountOutMinimum);
        erc20ByContract[marginAccountID][tokenIn] -= amountIn;
        erc20ByContract[marginAccountID][tokenOut] += amountOut;

        emit Swap(swapID, tokenIn, tokenOut, marginAccountID, amountIn, amountOut);
    }

    function exercise(uint marginAccountID, address erc721Token, address baseToken, uint id, address sender) external onlyRole(MARGIN_TRADING_ROLE){ 
        require(isAvailableErc721[erc721Token] && isAvailableErc20[baseToken], "Token is not available");
        uint amountOut = modularSwapRouter.exercise(erc721Token, baseToken, id);
        _deleteERC721TokenFromContractList(marginAccountID, erc721Token, id);
        erc20ByContract[marginAccountID][baseToken] += amountOut;
        IERC721(erc721Token).transferFrom(address(this), sender, id);

        emit Exercise(marginAccountID, id, erc721Token, baseToken, amountOut);
    }

    // PRIVATE FUNCTIONS //

    /**
     * @dev Deletes an ERC721 token from the contract's list for a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param token The address of the ERC721 token.
     * @param tokenID The ID of the token to delete.
     */
    function _deleteERC721TokenFromContractList(uint marginAccountID, address token, uint tokenID) private {
        uint[] storage userTokensByContract = erc721ByContract[marginAccountID][token];

        for(uint i = 0; i < userTokensByContract.length; i++) {
            if(userTokensByContract[i] == tokenID) {
                userTokensByContract[i] = userTokensByContract[userTokensByContract.length - 1]; 
                userTokensByContract.pop(); 
                return;
            }
        }

        require(false, "id not found");
    }

    /**
     * @dev Clears debts with liquidity pools for a margin account.
     * @param marginAccountID The ID of the margin account.
     * @param baseToken The base token address.
     */
    function _clearDebtsWithPools(uint marginAccountID, address baseToken, address liquidator) private {
        for (uint i; i < availableTokenToLiquidityPool.length; i++) {
            address liquidityPoolAddress = tokenToLiquidityPool[availableTokenToLiquidityPool[i]];   
            uint poolDebt = ILiquidityPool(liquidityPoolAddress).getDebtWithAccruedInterest(marginAccountID);
            if (poolDebt != 0) {
                uint amountInUSDC = modularSwapRouter.calculateAmountInERC20(availableTokenToLiquidityPool[i], baseToken, poolDebt);
                uint userUSDCbalance = getErc20ByContract(marginAccountID, baseToken);
                if (amountInUSDC > userUSDCbalance) {
                    uint amountOutMinimum = modularSwapRouter.calculateAmountOutERC20(baseToken, availableTokenToLiquidityPool[i], userUSDCbalance);
                    uint amountOut = modularSwapRouter.swapInput(baseToken, availableTokenToLiquidityPool[i], userUSDCbalance, amountOutMinimum);
                    erc20ByContract[marginAccountID][baseToken] -= userUSDCbalance;
                    IERC20(availableTokenToLiquidityPool[i]).transferFrom(insurancePool, address(this), poolDebt-amountOut); 
                } else {
                    uint amountIn = modularSwapRouter.swapOutput(availableTokenToLiquidityPool[i], baseToken, poolDebt);
                    emit LiquidateERC20(marginAccountID, baseToken, availableTokenToLiquidityPool[i], amountIn, poolDebt);
                    erc20ByContract[marginAccountID][baseToken] -= amountIn;
                }
                ILiquidityPool(liquidityPoolAddress).repay(marginAccountID, poolDebt);
            }
        }
        uint userUSDCbalanceAfterRepay = getErc20ByContract(marginAccountID, baseToken);
        uint liquidatorCommission = userUSDCbalanceAfterRepay*liquidatorFee/COEFFICIENT_DECIMALS;
        erc20ByContract[marginAccountID][baseToken] -= liquidatorCommission;
        IERC20(baseToken).transfer(liquidator, liquidatorCommission); 
        emit LiquidatorCommission(liquidatorCommission);
    }
}
