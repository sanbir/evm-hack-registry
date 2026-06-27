// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFeeService {
    function getFeeInfo(
        uint256 _chainId,
        address _feeToken
    ) external view returns (uint256 _base, uint256 _gasPrice, address _receiverAddress);

    function getServiceMessageFee(
        uint256 _toChain,
        address _feeToken,
        uint256 _gasLimit
    ) external view returns (uint256 amount, address receiverAddress);
}
