// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Interface of the IMORC20 core standard
 */
interface IMORC20 is IERC165 {
    event InterTransfer(
        bytes32 indexed orderId,
        address indexed fromAddress,
        uint256 indexed toChainId,
        bytes toAddress,
        uint256 fromAmount
    );

    event InterTransferAndCall(
        bytes32 indexed orderId,
        address indexed fromAddress,
        uint256 indexed toChainId,
        bytes toAddress,
        uint256 fromAmount,
        bytes payLoad
    );

    event InterReceive(
        bytes32 indexed orderId,
        uint256 indexed fromChain,
        bytes fromAddress,
        address toAddress,
        uint256 amount
    );

    event InterReceiveAndExecute(
        bytes32 indexed orderId,
        uint256 indexed fromchain,
        bytes srcAddress,
        address toAddress,
        bool result,
        bytes reason
    );

    /**
     * estimate interchain transfer fee
     */
    function estimateFee(uint256 toChain, uint256 gasLimit) external view returns (address feeToken, uint256 fee);

    /**
     * returns the circulating supply on current chain
     */
    function currentChainSupply() external view returns (uint);

    /**
     *  returns the address of the ERC20 token
     */
    function token() external view returns (address);

    function interTransfer(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit
    ) external payable;

    function interTransferAndCall(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit,
        bytes memory _refundAddress,
        bytes memory _messageData
    ) external payable;
}
