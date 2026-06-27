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

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarginAccountManager} from "../../interfaces/IMarginAccountManager.sol";
import {EphemeralERC20Type1} from "./EphemeralERC20Type1.sol";
import {IOneClickProxy} from "../../interfaces/oneClick/IOneClickProxy.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoter} from "../../interfaces/modularSwapRouter/uniswap/IQuoter.sol";

contract OneClickEphemeralSwapOutput is AccessControl {
    uint24 constant POOL_FEE = 500;

    IMarginAccountManager public marginAccountManager;
    IOneClickProxy public oneClickProxy;
    ISwapRouter public swapRouter;
    IQuoter public quoter;

    bytes32 public constant FACADE_ROLE = keccak256("FACADE_ROLE");

    mapping (address => address) originalTokenToEphemeralToken;

    constructor(
        IMarginAccountManager _marginAccountManager,
        IOneClickProxy _oneClickProxy,
        ISwapRouter _swapRouter,
        IQuoter _quoter
    ) {
        marginAccountManager = _marginAccountManager;
        oneClickProxy = _oneClickProxy;
        swapRouter = _swapRouter;
        quoter = _quoter;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyApprovedOrOwner(uint marginAccountID) {
        require(marginAccountManager.isApprovedOrOwner(msg.sender, marginAccountID), "You are not the owner of the token");
        _;
    }


    function approveERC20(address token, address to, uint amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).approve(to, amount);
    }

    function setOriginalTokenToEphemeralToken(address original, address ephemeral) external onlyRole(DEFAULT_ADMIN_ROLE) {
        originalTokenToEphemeralToken[original] = ephemeral;
    }

    function swapOutput(
        uint marginAccountID, 
        address tokenIn, 
        address tokenOut, 
        uint amountOut, 
        uint amountInMaximum
    ) external onlyRole(FACADE_ROLE) returns (uint amountIn) {
        address ephemeralToken = originalTokenToEphemeralToken[tokenOut];
        EphemeralERC20Type1(ephemeralToken).mintTo(address(this), amountInMaximum);
        oneClickProxy.provideERC20(marginAccountID, ephemeralToken, amountInMaximum);
        oneClickProxy.withdrawERC20(marginAccountID, tokenOut, amountInMaximum);
        amountIn = swapRouter.exactOutput(
            ISwapRouter.ExactOutputParams({
                path: abi.encodePacked(tokenIn, POOL_FEE, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum
            })
        );
        oneClickProxy.provideERC20(marginAccountID, tokenIn, IERC20(tokenIn).balanceOf(address(this)));
        oneClickProxy.provideERC20(marginAccountID, tokenOut, IERC20(tokenOut).balanceOf(address(this)));
        oneClickProxy.withdrawERC20(marginAccountID, ephemeralToken, amountInMaximum);
        EphemeralERC20Type1(ephemeralToken).burnTo(address(this), amountInMaximum);
    }

    function getAmountIn(
        address tokenIn,
        address tokenOut,
        uint amountOut
    ) external returns (uint amountIn) {
        amountIn = quoter.quoteExactOutput(abi.encodePacked(tokenIn, POOL_FEE, tokenOut), amountOut);
    }

}