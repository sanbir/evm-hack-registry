// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import './SafeOwnable.sol';
import 'hardhat/console.sol';

abstract contract Random is Context, SafeOwnable {
    using SafeMath for uint256;
    
    uint private requestId = 0;
    mapping(bytes32 => bool) internal randomRequest;
    mapping(bytes32 => uint) internal randomResult;
    address public linkAccessor;

    event RequestRandom(bytes32 requestId, uint256 seed);
    event FulfillRandom(bytes32 requestId, uint256 randomness);
    event NewLinkAccessor(address oldLinkAccessor, address newLinkAccessor);

    constructor(address _linkAccessor) {
        require(_linkAccessor != address(0), "_linkAccessor is zero");
        linkAccessor = _linkAccessor;
        emit NewLinkAccessor(address(0), linkAccessor);
    }

    function setLinkAccessor(address _linkAccessor) external onlyOwner {
        require(_linkAccessor != address(0), "_linkAccessor is zero");
        emit NewLinkAccessor(linkAccessor, _linkAccessor);
        linkAccessor = _linkAccessor; 
    }

    function _requestRandom(uint256 _seed) internal returns (bytes32) {
        bytes32 _requestId = bytes32(requestId);
        emit RequestRandom(_requestId, _seed);
        randomRequest[_requestId] = true;
        requestId = requestId.add(1);
        return _requestId;
    }

    function fulfillRandomness(bytes32 _requestId, uint256 _randomness) external {
        require(_msgSender() == address(linkAccessor), "Only linkAccessor can call");
        _randomness = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty, tx.origin, block.coinbase, block.number, _randomness)));
        randomResult[_requestId] = _randomness; 
        delete randomRequest[bytes32(requestId)];
        emit FulfillRandom(_requestId, _randomness);
        finishRandom(_requestId);
    }

    function finishRandom(bytes32 _requestId) internal virtual {
        delete randomResult[_requestId];
    }
}
