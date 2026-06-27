// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../morc20/MORC20Token.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract MORC20Pausable is MORC20Token, Pausable {
    constructor(
        string memory _name,
        string memory _symbol,
        address _mosAddress
    ) MORC20Token(_name, _symbol, _mosAddress) {}

    function interTransfer(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit
    ) external payable virtual override whenNotPaused {
        return _interTransfer(_fromAddress, _toChainId, _toAddress, _fromAmount, _gasLimit);
    }

    function interTransferAndCall(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit,
        bytes memory _refundAddress,
        bytes memory _messageData
    ) external payable virtual override whenNotPaused {
        _interTransferAndCall(
            _fromAddress,
            _toChainId,
            _toAddress,
            _fromAmount,
            _gasLimit,
            _refundAddress,
            _messageData
        );
    }

    function pauseSendTokens(bool pause) external onlyOwner {
        pause ? _pause() : _unpause();
    }
}
