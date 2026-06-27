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

import {IPositionManagerERC20} from "../../interfaces/modularSwapRouter/IPositionManagerERC20.sol"; 
import {IQuoter} from "../../interfaces/modularSwapRouter/uniswap/IQuoter.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
/**
 * @title UniswapModule
 * @dev A module for managing token swaps and liquidity positions using Uniswap.
 * @notice This contract provides functions to facilitate token swaps and manage liquidity on Uniswap. 
 * It uses AccessControl for role-based access management and integrates with Uniswap's swap router and quoter.
 * @author 0nika0
 */
abstract contract UniswapModuleBase is IPositionManagerERC20, AccessControl {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant MODULAR_SWAP_ROUTER_ROLE = keccak256("MODULAR_SWAP_ROUTER_ROLE");

    address public marginAccount;

    address public tokenInContract;
    uint24 public poolFee;
    address public tokenOutContract;

    ISwapRouter public swapRouter;
    IQuoter public quoter;

    constructor(
        address _marginAccount,
        address _tokenInContract,
        uint24 _poolFee,
        address _tokenOutContract,
        ISwapRouter _swapRouter,
        IQuoter _quoter
    ) {
        marginAccount = _marginAccount;
        tokenInContract = _tokenInContract;
        poolFee = _poolFee;
        tokenOutContract = _tokenOutContract;
        swapRouter = _swapRouter;
        quoter = _quoter;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }


    // VIEW FUNCTIONS //

    function getPositionValue(uint256 amountIn) external virtual returns (uint amountOut) {}

    function getInputPositionValue(uint256 amountIn) external returns (uint amountOut) {
        amountOut = quoter.quoteExactInput(abi.encodePacked(tokenInContract, poolFee, tokenOutContract), amountIn);
    }

    function getOutputPositionValue(uint256 amountOut) public returns (uint amountIn) {
        amountIn = quoter.quoteExactOutput(abi.encodePacked(tokenInContract, poolFee, tokenOutContract), amountOut);
    }

    // EXTERNAL FUNCTION //

    /**
     * @notice Approves the maximum amount of the input token to be spent by the swap router.
     * @dev This function can be called by any account.
     */
    function allApprove() external {
        ERC20(tokenInContract).approve(address(swapRouter), type(uint256).max);
        ERC20(tokenOutContract).approve(address(swapRouter), type(uint256).max);
    }

    // ONLY MODULAR_SWAP_ROUTER_ROLE FUNCTION //

    function liquidate(uint256 amountIn) external onlyRole(MODULAR_SWAP_ROUTER_ROLE) returns(uint amountOut) {

        ERC20(tokenInContract).transferFrom(marginAccount, address(this), amountIn);

        ISwapRouter.ExactInputParams memory params = _prepareInputParams(amountIn);

        amountOut = swapRouter.exactInput(params);
        ERC20(tokenOutContract).transfer(marginAccount, amountOut);
    }

    function swapInput(uint amountIn, uint amountOutMinimum) external onlyRole(MODULAR_SWAP_ROUTER_ROLE) returns(uint amountOut) {
        ERC20(tokenInContract).transferFrom(marginAccount, address(this), amountIn);

        ISwapRouter.ExactInputParams memory params = _prepareInputParams(amountIn);
        params.amountOutMinimum = amountOutMinimum;
        amountOut = swapRouter.exactInput(params);

        ERC20(tokenOutContract).transfer(marginAccount, amountOut);
    }

    function swapOutput(uint amountOut) external onlyRole(MODULAR_SWAP_ROUTER_ROLE) returns(uint amountIn) {
        ISwapRouter.ExactOutputParams memory params = _prepareOutputParams(amountOut);

        amountIn = getOutputPositionValue(amountOut);

        params.amountInMaximum = amountIn;
        ERC20(tokenOutContract).transferFrom(marginAccount, address(this), amountIn);

        swapRouter.exactOutput(params);

        ERC20(tokenInContract).transfer(marginAccount, amountOut);
    }

    // PRIVATE FUNCTION //

    /**
     * @notice Prepares the parameters for an exact input swap.
     * @param amount The amount of input tokens.
     * @return params The prepared ExactInputParams struct.
     */
    function _prepareInputParams(uint256 amount) private view returns(ISwapRouter.ExactInputParams memory params) {
        params = ISwapRouter.ExactInputParams({
            path: abi.encodePacked(tokenInContract, poolFee, tokenOutContract),
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0
        });
    }

    /**
     * @notice Prepares the parameters for an exact output swap.
     * @param amount The amount of output tokens.
     * @return params The prepared ExactOutputParams struct.
     */
    function _prepareOutputParams(uint256 amount) private view returns(ISwapRouter.ExactOutputParams memory params) {
        params = ISwapRouter.ExactOutputParams({
            path: abi.encodePacked(tokenInContract, poolFee, tokenOutContract),
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: amount,
            amountInMaximum: type(uint256).max 
        });
    }
}
