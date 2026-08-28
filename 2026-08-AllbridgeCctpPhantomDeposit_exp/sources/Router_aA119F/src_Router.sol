// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ChainGasUsage} from "./ChainGasUsage.sol";
import {ISwap} from "./interfaces/ISwap.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Router is ChainGasUsage {
    using SafeERC20 for IERC20;

    uint256 public feeBp;
    uint256 public constant BP_DENOMINATOR = 10000;
    uint8 public constant SYSTEM_DECIMALS = 9;

    // Swap contract => registered
    mapping(address swap => bool registered) public swaps;
    // TokenMessenger contract => registered
    mapping(address tokenMessenger => bool registered) public tokenMessengers;
    // Relayer address => registered
    mapping(address relayer => bool registered) public relayers;
    // intermediaryToken => destinationChain => destinationToken => info
    enum DestinationToken {
        Disabled,
        Enabled,
        EnabledWithSwap
    }
    mapping(
        address intermediaryToken
            => mapping(uint32 destinationChain => mapping(bytes32 destinationToken => DestinationToken info))
    ) internal destinationTokenInfo;
    // nonce for messages
    uint256 public nonce;
    // messageHash => used
    mapping(bytes32 messageHash => bool used) public usedMessages;

    // token address => amount that can be withdrawn by admin
    mapping(address token => uint256 amount) public withdrawableAmount;

    event TokenSent(
        address sender,
        address sourceToken,
        uint256 amountIn,
        uint256 normalizedAmountOut,
        uint32 sourceChain,
        uint32 destinationChain,
        bytes32 destinationToken,
        bytes32 recipient,
        address intermediaryToken,
        uint256 nonce,
        bytes32 messageHash,
        address swapAddr,
        address tokenMessengersAddr,
        bytes32 metadata
    );
    event TokenReceived(
        uint256 normalizedAmountIn,
        uint256 fee,
        uint256 amountOut,
        uint32 sourceChain,
        uint32 destinationChain,
        bytes32 destinationToken,
        bytes32 recipient,
        address intermediaryToken,
        uint256 nonce,
        bytes32 messageHash,
        address swapAddr,
        address tokenMessengersAddr
    );

    address public constant ETH_MARKER = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint32 public immutable CHAIN_ID;

    uint32 public constant ACTION_ROUTER = DEFAULT_ACTION;
    uint32 public constant ACTION_SWAP = 1;

    constructor(uint32 _chainId) Ownable(msg.sender) {
        CHAIN_ID = _chainId;
    }

    function registerSwap(address swap, bool registered) external onlyOwner {
        swaps[swap] = registered;
    }

    function registerTokenMessenger(address tokenMessenger, bool registered) external onlyOwner {
        tokenMessengers[tokenMessenger] = registered;
        address token = ITokenMessenger(tokenMessenger).token();
        if (registered) {
            IERC20(token).forceApprove(tokenMessenger, type(uint256).max);
        } else {
            IERC20(token).forceApprove(tokenMessenger, 0);
        }
    }

    function registerRelayer(address relayer, bool registered) external onlyOwner {
        relayers[relayer] = registered;
    }

    // Getter for full destination token info
    function getDestinationTokenInfo(address intermediaryToken, uint32 destinationChain, bytes32 destinationToken)
        external
        view
        returns (DestinationToken)
    {
        return destinationTokenInfo[intermediaryToken][destinationChain][destinationToken];
    }

    // Extended setter to also control whether swap is required on destination chain
    function setDestinationToken(
        address intermediaryToken,
        uint32 destinationChain,
        bytes32 destinationToken,
        DestinationToken status
    ) external onlyOwner {
        destinationTokenInfo[intermediaryToken][destinationChain][destinationToken] = status;
    }

    function setFee(uint256 _feeBp) external onlyOwner {
        require(_feeBp <= BP_DENOMINATOR, "Fee too high");
        feeBp = _feeBp;
    }

    struct SendParams {
        uint256 amount;
        uint256 minSwapAmount;
        bytes32 destinationToken;
        bytes32 destinationAddress;
        bytes32 metadata;
        address sourceToken;
        address swapAddr;
        address tokenMessengerAddr;
        uint32 destinationChain;
    }

    function sendToken(SendParams calldata params) external payable {
        require(tokenMessengers[params.tokenMessengerAddr], "No tokenMessenger registered");

        address intermediaryToken = ITokenMessenger(params.tokenMessengerAddr).token();

        DestinationToken status =
            destinationTokenInfo[intermediaryToken][params.destinationChain][params.destinationToken];
        require(status != DestinationToken.Disabled, "Destination token not enabled");

        uint256 swappedAmount = params.amount;

        uint256 msgValueForMessenger = msg.value;
        // Subtract amount from message value if gas token is used
        if (params.sourceToken == ETH_MARKER) {
            require(msgValueForMessenger >= params.amount, "Low msg value for amount");
            msgValueForMessenger -= params.amount;
        }

        {
            // Calculate and check router fee plus swap fee if it needed
            uint256 routerFee = getTransactionFeeInNative(params.destinationChain, ACTION_ROUTER);
            if (status == DestinationToken.EnabledWithSwap) {
                routerFee += getTransactionFeeInNative(params.destinationChain, ACTION_SWAP);
            }
            if (routerFee > 0) {
                require(msgValueForMessenger >= routerFee, "Low msg value for fee");
                msgValueForMessenger -= routerFee;
                withdrawableAmount[ETH_MARKER] += routerFee;
            }
        }

        // Swap if needed
        if (params.sourceToken != intermediaryToken) {
            require(swaps[params.swapAddr], "No swap registered");

            uint256 msgValueForSwap = 0;
            if (params.sourceToken == ETH_MARKER) {
                msgValueForSwap = params.amount;
            } else {
                IERC20(params.sourceToken).safeTransferFrom(msg.sender, params.swapAddr, params.amount);
            }

            swappedAmount = ISwap(params.swapAddr).swap{value: msgValueForSwap}(
                params.amount, params.minSwapAmount, address(this), params.sourceToken, intermediaryToken
            );
        } else if (params.sourceToken != ETH_MARKER) {
            // Else transfer token amount to the contract
            IERC20(params.sourceToken).safeTransferFrom(msg.sender, address(this), params.amount);
        }

        uint256 currentNonce = ++nonce;
        uint256 normalizedAmount = _normalize(swappedAmount, _getDecimals(intermediaryToken));
        bytes32 messageHash = _calculateMessageHash(
            currentNonce,
            params.destinationAddress,
            params.destinationToken,
            normalizedAmount,
            CHAIN_ID,
            params.destinationChain
        );

        ITokenMessenger(params.tokenMessengerAddr).sendMessage{value: msgValueForMessenger}(
            params.destinationChain,
            params.destinationAddress,
            swappedAmount,
            normalizedAmount,
            abi.encodePacked(messageHash)
        );

        emit TokenSent(
            msg.sender,
            params.sourceToken,
            params.amount,
            normalizedAmount,
            CHAIN_ID,
            params.destinationChain,
            params.destinationToken,
            params.destinationAddress,
            intermediaryToken,
            currentNonce,
            messageHash,
            params.swapAddr,
            params.tokenMessengerAddr,
            params.metadata
        );
    }

    function receiveToken(
        uint256 normalizedAmount,
        uint256 _nonce,
        uint32 sourceChain,
        bytes32 destinationToken,
        bytes32 recipient,
        address swapAddr,
        address tokenMessengersAddr,
        uint256 minSwapAmount
    ) external {
        require(tokenMessengers[tokenMessengersAddr], "No tokenMessengers registered");

        address recipientAddr = address(uint160(uint256(recipient)));
        require(relayers[msg.sender] || msg.sender == recipientAddr, "Unauthorized relayer");
        address intermediaryToken = ITokenMessenger(tokenMessengersAddr).token();
        bytes32 messageHash =
            _calculateMessageHash(_nonce, recipient, destinationToken, normalizedAmount, sourceChain, CHAIN_ID);
        require(!usedMessages[messageHash], "Message already used");

        uint256 receivedAmount = ITokenMessenger(tokenMessengersAddr).receivedTokenAmount(messageHash);
        require(receivedAmount > 0, "Message not received");

        usedMessages[messageHash] = true;

        uint256 actualAmount = _denormalize(normalizedAmount, _getDecimals(intermediaryToken));

        uint256 fee = (actualAmount * feeBp) / BP_DENOMINATOR;
        uint256 amountAfterFee = actualAmount - fee;

        withdrawableAmount[intermediaryToken] += (receivedAmount - amountAfterFee);

        address destTokenAddr = address(uint160(uint256(destinationToken)));

        uint256 amountOut = amountAfterFee;

        if (intermediaryToken != destTokenAddr) {
            require(swaps[swapAddr], "No swap registered");

            IERC20(intermediaryToken).safeTransfer(swapAddr, amountAfterFee);
            amountOut =
                ISwap(swapAddr).swap(amountAfterFee, minSwapAmount, recipientAddr, intermediaryToken, destTokenAddr);
        } else {
            if (destTokenAddr == ETH_MARKER) {
                (bool success,) = recipientAddr.call{value: amountAfterFee}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(intermediaryToken).safeTransfer(recipientAddr, amountAfterFee);
            }
        }

        emit TokenReceived(
            normalizedAmount,
            fee,
            amountOut,
            sourceChain,
            CHAIN_ID,
            destinationToken,
            recipient,
            intermediaryToken,
            _nonce,
            messageHash,
            swapAddr,
            tokenMessengersAddr
        );
    }

    function getRelayerFeeInNative(uint32 destinationChain, bytes32 destinationToken, address tokenMessengerAddr)
        external
        view
        returns (uint256)
    {
        uint256 totalFee = this.getTransactionFeeInNative(destinationChain, ACTION_ROUTER);
        address intermediaryToken = ITokenMessenger(tokenMessengerAddr).token();
        DestinationToken status = destinationTokenInfo[intermediaryToken][destinationChain][destinationToken];

        if (status == DestinationToken.EnabledWithSwap) {
            totalFee += this.getTransactionFeeInNative(destinationChain, ACTION_SWAP);
        }
        totalFee += ITokenMessenger(tokenMessengerAddr).getTransactionFeeInNative(destinationChain);
        return totalFee;
    }

    function getAmountOut(uint256 normalizedAmount, address intermediaryToken, address destTokenAddr, address swapAddr)
        external
        returns (uint256)
    {
        uint256 actualAmount = _denormalize(normalizedAmount, _getDecimals(intermediaryToken));

        uint256 fee = (actualAmount * feeBp) / BP_DENOMINATOR;
        uint256 amountAfterFee = actualAmount - fee;

        if (intermediaryToken != destTokenAddr) {
            return ISwap(swapAddr).quote(amountAfterFee, intermediaryToken, destTokenAddr);
        } else {
            return amountAfterFee;
        }
    }

    function _calculateMessageHash(
        uint256 _nonce,
        bytes32 recipient,
        bytes32 destinationToken,
        uint256 amount,
        uint32 sourceChain,
        uint32 destinationChain
    ) internal pure returns (bytes32 messageHash) {
        // Tests show that this approach uses less gas.
        // forge-lint: disable-start(asm-keccak256)
        return keccak256(abi.encodePacked(_nonce, recipient, destinationToken, amount, sourceChain, destinationChain));
    }

    /**
     * @dev Normalizes a token amount to the standard 9 decimals (SYSTEM_DECIMALS).
     * This ensures consistency for calculations across different tokens with varying decimals.
     * @param amount The original token amount to be normalized.
     * @param decimals The original decimal count of the token.
     * @return The normalized token amount.
     */
    function _normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= SYSTEM_DECIMALS) {
            return amount / (10 ** (decimals - SYSTEM_DECIMALS));
        } else {
            return amount * (10 ** (SYSTEM_DECIMALS - decimals));
        }
    }

    /**
     * @dev Converts a normalized token amount from SYSTEM_DECIMALS (9) back to its original decimal representation.
     * This is used when transferring tokens to users in their original decimal format.
     * @param amount The normalized token amount.
     * @param decimals The target decimal count of the token.
     * @return The denormalized token amount in the original decimals.
     */
    function _denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals >= SYSTEM_DECIMALS) {
            return amount * (10 ** (decimals - SYSTEM_DECIMALS));
        } else {
            return amount / (10 ** (SYSTEM_DECIMALS - decimals));
        }
    }

    function _getDecimals(address token) internal view returns (uint8) {
        if (token == ETH_MARKER) {
            return 18;
        }
        return ERC20(token).decimals();
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        if (amount == 0) {
            amount = withdrawableAmount[token];
        }
        require(amount <= withdrawableAmount[token], "Insufficient withdrawable amount");
        withdrawableAmount[token] -= amount;

        if (token == ETH_MARKER) {
            (bool success,) = to.call{value: amount}("");
            require(success, "Native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
