// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import "../SwapImplBase.sol";
import {Address0Provided, SwapFailed, PartialSwapsNotAllowed} from "../../errors/SocketErrors.sol";

interface WrappedToken {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

/**
 * @title Abstract Implementation Contract.
 * @notice All Swap Implementation will follow this interface.
 * @author Socket dot tech.
 */
contract WrappedTokenSwapperImpl is SwapImplBase {
    /// @notice SafeTransferLib - library for safe and optimised operations on ERC20 tokens
    using SafeTransferLib for ERC20;

    bytes32 public immutable Identifier = "wrappedTokenSwapperImpl";

    constructor(
        address _socketGateway,
        address _socketDeployFactory
    ) SwapImplBase(_socketGateway, _socketDeployFactory) {}

    receive() external payable {}

    fallback() external payable {}

    function performAction(
        address fromToken,
        address toToken,
        uint256 amount,
        address receiverAddress,
        bytes32 metadata,
        bytes calldata swapExtraData
    ) external payable override returns (uint256) {
        uint256 _initialBalanceTokenOut;
        uint256 _finalBalanceTokenOut;

        // Swap Native to Wrapped Token
        if (fromToken == NATIVE_TOKEN_ADDRESS) {
            _initialBalanceTokenOut = ERC20(toToken).balanceOf(socketGateway);
            (bool success, ) = toToken.call{value: amount}(swapExtraData);

            if (!success) {
                revert SwapFailed();
            }

            _finalBalanceTokenOut = ERC20(toToken).balanceOf(socketGateway);

            require(
                (_finalBalanceTokenOut - _initialBalanceTokenOut) == amount,
                "Invalid wrapper contract"
            );

            // Send weth to user
            ERC20(toToken).transfer(receiverAddress, amount);
        } else {
            _initialBalanceTokenOut = address(socketGateway).balance;

            // Swap Wrapped Token To Native Token
            ERC20(fromToken).safeTransferFrom(
                msg.sender,
                socketGateway,
                amount
            );

            (bool success, ) = fromToken.call(swapExtraData);

            if (!success) {
                revert SwapFailed();
            }

            _finalBalanceTokenOut = address(socketGateway).balance;

            require(
                (_finalBalanceTokenOut - _initialBalanceTokenOut) == amount,
                "Invalid wrapper contract"
            );

            // send ETH to the user
            payable(receiverAddress).transfer(amount);
        }

        emit SocketSwapTokens(
            fromToken,
            toToken,
            amount,
            amount,
            Identifier,
            receiverAddress,
            metadata
        );

        return amount;
    }

    /**
     * @notice function to swapWithIn SocketGateway - swaps tokens on the chain to socketGateway as recipient
     * @param fromToken token to be swapped
     * @param toToken token to which fromToken has to be swapped
     * @param amount amount of fromToken being swapped
     * @param swapExtraData encoded value of properties in the swapData Struct
     * @return swapped amount (in toToken Address)
     */
    function performActionWithIn(
        address fromToken,
        address toToken,
        uint256 amount,
        bytes32 metadata,
        bytes calldata swapExtraData
    ) external payable override returns (uint256, address) {
        uint256 _initialBalanceTokenOut;
        uint256 _finalBalanceTokenOut;

        // Swap Native to Wrapped Token
        if (fromToken == NATIVE_TOKEN_ADDRESS) {
            _initialBalanceTokenOut = ERC20(toToken).balanceOf(socketGateway);
            (bool success, ) = toToken.call{value: amount}(swapExtraData);

            if (!success) {
                revert SwapFailed();
            }

            _finalBalanceTokenOut = ERC20(toToken).balanceOf(socketGateway);

            require(
                (_finalBalanceTokenOut - _initialBalanceTokenOut) == amount,
                "Invalid wrapper contract"
            );
        } else {
            _initialBalanceTokenOut = address(socketGateway).balance;

            // Swap Wrapped Token To Native Token
            ERC20(fromToken).safeTransferFrom(
                msg.sender,
                socketGateway,
                amount
            );

            (bool success, ) = fromToken.call(swapExtraData);

            if (!success) {
                revert SwapFailed();
            }

            _finalBalanceTokenOut = address(socketGateway).balance;

            require(
                (_finalBalanceTokenOut - _initialBalanceTokenOut) == amount,
                "Invalid wrapper contract"
            );
        }

        emit SocketSwapTokens(
            fromToken,
            toToken,
            _finalBalanceTokenOut - _initialBalanceTokenOut,
            amount,
            Identifier,
            socketGateway,
            metadata
        );

        return (_finalBalanceTokenOut - _initialBalanceTokenOut, toToken);
    }
}
