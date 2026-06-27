// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IButterReceiver {
    //_srcToken received token (wtoken or erc20 token)
    function onReceived(
        bytes32 _orderId,
        address _srcToken,
        uint256 _amount,
        uint256 _fromChain,
        bytes calldata _from,
        bytes calldata _payload
    ) external;
}
