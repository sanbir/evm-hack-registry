// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMORC20Receiver {
    function onMORC20Received(
        uint256 _fromChainId,
        bytes memory _fromAddress,
        uint256 _amount,
        bytes32 _orderId,
        bytes calldata _message
    ) external returns (bool);
}
