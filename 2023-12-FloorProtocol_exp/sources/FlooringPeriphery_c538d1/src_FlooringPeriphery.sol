// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryPayments.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";

import {IFlooring} from "./interface/IFlooring.sol";
import {OwnedUpgradeable} from "./library/OwnedUpgradeable.sol";
import {CurrencyTransfer} from "./library/CurrencyTransfer.sol";
import {ERC721Transfer} from "./library/ERC721Transfer.sol";
import {TicketRecord, SafeBoxKey, SafeBox} from "./logic/Structs.sol";
import "./logic/SafeBox.sol";
import "./Errors.sol";
import "./Constants.sol";
import {FlooringGetter} from "./FlooringGetter.sol";
import "./interface/IWETH9.sol";
import "./Multicall.sol";

contract FlooringPeriphery is FlooringGetter, OwnedUpgradeable, UUPSUpgradeable, IERC721Receiver, Multicall {
    error NotRouterOrWETH9();
    error InsufficientWETH9();

    address public immutable uniswapRouter;
    address public immutable WETH9;

    constructor(address flooring, address uniswapV3Router, address _WETH9) payable FlooringGetter(flooring) {
        uniswapRouter = uniswapV3Router;
        WETH9 = _WETH9;
    }

    // required by the OZ UUPS module
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function initialize() public initializer {
        __Owned_init();
        __UUPSUpgradeable_init();
    }

    function fragmentAndSell(
        address collection,
        uint256[] calldata tokenIds,
        bool unwrapWETH,
        ISwapRouter.ExactInputParams memory swapParam
    ) external payable returns (uint256 swapOut) {
        uint256 fragmentTokenAmount = tokenIds.length * Constants.FLOOR_TOKEN_AMOUNT;

        address floorToken = fragmentTokenOf(collection);

        /// approve all
        approveAllERC721(collection, address(_flooring));
        approveAllERC20(floorToken, uniswapRouter, fragmentTokenAmount);

        /// transfer tokens into this
        ERC721Transfer.safeBatchTransferFrom(collection, msg.sender, address(this), tokenIds);

        /// fragment
        _flooring.fragmentNFTs(collection, tokenIds, msg.sender);
        IERC20(floorToken).transferFrom(msg.sender, address(this), fragmentTokenAmount);

        swapOut = ISwapRouter(uniswapRouter).exactInput(swapParam);

        if (unwrapWETH) {
            unwrapWETH9(swapOut, msg.sender);
        }
    }

    function buyAndClaimExpired(
        address collection,
        uint256[] calldata tokenIds,
        uint256 claimCnt,
        uint256 maxCostToClaim,
        address swapTokenIn,
        ISwapRouter.ExactOutputParams memory swapParam
    ) external payable returns (uint256 tokenCost, uint256 claimCost) {
        _flooring.tidyExpiredNFTs(collection, tokenIds);
        return buyAndClaimVault(collection, claimCnt, maxCostToClaim, swapTokenIn, swapParam);
    }

    function buyAndClaimVault(
        address collection,
        uint256 claimCnt,
        uint256 maxCostToClaim,
        address swapTokenIn,
        ISwapRouter.ExactOutputParams memory swapParam
    ) public payable returns (uint256 tokenCost, uint256 claimCost) {
        uint256 fragmentTokenAmount = claimCnt * Constants.FLOOR_TOKEN_AMOUNT;

        address floorToken = fragmentTokenOf(collection);

        approveAllERC20(floorToken, address(_flooring), fragmentTokenAmount);

        tokenCost = swapExactOutput(msg.sender, swapTokenIn, swapParam);

        uint256 feeCost = swapParam.amountOut > fragmentTokenAmount ? swapParam.amountOut - fragmentTokenAmount : 0;
        if (feeCost > 0) {
            _flooring.addTokens(address(this), floorToken, feeCost);
        }

        claimCost = _flooring.claimRandomNFT(collection, claimCnt, maxCostToClaim, msg.sender);
        /// no extra fee or fee matching
        require(feeCost == 0 || claimCost == feeCost);
    }

    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable {
        uint256 balanceWETH9 = IWETH9(WETH9).balanceOf(address(this));
        if (balanceWETH9 < amountMinimum) {
            revert InsufficientWETH9();
        }

        if (balanceWETH9 > 0) {
            IWETH9(WETH9).withdraw(balanceWETH9);
            CurrencyTransfer.safeTransfer(CurrencyTransfer.NATIVE, recipient, balanceWETH9);
        }
    }

    function swapExactOutput(address payer, address tokenIn, ISwapRouter.ExactOutputParams memory param)
        internal
        returns (uint256 amountIn)
    {
        if (tokenIn == WETH9 && address(this).balance >= param.amountInMaximum) {
            amountIn = ISwapRouter(uniswapRouter).exactOutput{value: param.amountInMaximum}(param);
            IPeripheryPayments(uniswapRouter).refundETH();
            if (address(this).balance > 0) {
                CurrencyTransfer.safeTransfer(CurrencyTransfer.NATIVE, payer, address(this).balance);
            }
        } else {
            approveAllERC20(tokenIn, uniswapRouter, param.amountInMaximum);
            CurrencyTransfer.safeTransferFrom(tokenIn, payer, address(this), param.amountInMaximum);
            amountIn = ISwapRouter(uniswapRouter).exactOutput(param);

            if (param.amountInMaximum > amountIn) {
                CurrencyTransfer.safeTransfer(tokenIn, payer, param.amountInMaximum - amountIn);
            }
        }
    }

    function approveAllERC20(address token, address spender, uint256 desireAmount) private {
        if (desireAmount == 0) {
            return;
        }
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < desireAmount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }

    function approveAllERC721(address collection, address spender) private {
        bool approved = IERC721(collection).isApprovedForAll(address(this), spender);
        if (!approved) {
            IERC721(collection).setApprovalForAll(spender, true);
        }
    }

    function onERC721Received(address, /*operator*/ address, /*from*/ uint256, /*tokenId*/ bytes calldata /*data*/ )
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (msg.sender != uniswapRouter && msg.sender != WETH9) revert NotRouterOrWETH9();
    }
}
