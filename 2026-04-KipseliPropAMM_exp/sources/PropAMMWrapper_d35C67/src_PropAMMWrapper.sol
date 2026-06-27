// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Signer} from "./Signer.sol";

interface IQuote {
    function quote(address tokenIn, uint amountIn, address tokenOut, uint timestampInMilisec, bytes memory sig) external view returns(uint amountOut);    
}

interface ISwap {
    function swap(address tokenIn, uint amountIn, address tokenOut, uint minOutAmount, uint quoteTimestamp, bytes calldata verificationData) external returns(uint amountOut);
}


contract PropAMMWrapper {
    using SafeERC20 for IERC20;

    address immutable propAMM;
    Signer immutable signer;
 
    constructor(address _propAMM) {
        propAMM = _propAMM;
        signer = new Signer(0x8888888888888888888888888888888888888888888888888888888888888888);
    }

    function quote(address tokenIn, uint amountIn, address tokenOut) external view returns(uint amountOut) {
        bytes memory sig = signer.generateQuoteSignature(tokenIn, amountIn, tokenOut, block.timestamp * 1000);

        amountOut = IQuote(propAMM).quote(tokenIn, amountIn, tokenOut, block.timestamp * 1000, sig);
    }

    function swap(address tokenIn, uint amountIn, address tokenOut, uint minOutAmount, address recipient) external returns(uint amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(propAMM, amountIn);

        amountOut = ISwap(propAMM).swap(tokenIn, amountIn, tokenOut, minOutAmount, block.timestamp, new bytes(0));

        IERC20(tokenOut).safeTransfer(recipient, amountOut);        
    }
}