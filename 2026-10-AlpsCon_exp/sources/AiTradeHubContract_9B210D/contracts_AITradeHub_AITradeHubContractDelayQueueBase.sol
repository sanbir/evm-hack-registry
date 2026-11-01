//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";


abstract contract AiTradeHubContractDelayQueueBase is AITradeHubContractCommon, EIP712 {
    using ECDSA for bytes32;

    struct DelayRequest {
        address owner;
        bool executed;
        bool canceled;
        address to;
        uint64 executeAfter;
        uint256 amount;
    }

    enum DelayRequestStatus {
        NONE,
        PENDING,
        EXECUTABLE,
        EXECUTED,
        EXPIRED,
        CANCELED
    }

    uint64 internal delay = 24 hours;
    uint64 internal expires = 5 days;

    enum QueueKey {WITHDRAW_FUNDS, TRANSFER_FUNDS, MIGRATE_WALLET, ENHANCED_SECURITY}

    mapping(QueueKey => mapping(address => uint256[])) private openIds;          // key => owner => ids
    mapping(QueueKey => mapping(uint256 => uint256)) private indexPlusOne;       // key => id => idx+1
    mapping(QueueKey => mapping(uint256 => DelayRequest)) internal delayRequests;
    mapping(QueueKey => uint256) private requestId;
    uint256 private constant MAX_OPEN_REQUESTS = 3;
    mapping(address => uint256) private sigNonces;

    constructor() EIP712("AITradeHubContractDelayAction", "1"){}

    function listDelayOpenRequests(QueueKey key, address owner)
    external
    view
    returns (uint256[] memory ids)
    {
        return _openDelayQueueList(key, owner);
    }

    function getDelayRequest(QueueKey key, uint256 id)
    external
    view
    returns (
        address owner,
        address to,
        uint256 amount,
        uint64 executeAfter,
        DelayRequestStatus status,
        uint256 secondsRemaining
    )
    {
        DelayRequest storage r = delayRequests[key][id];

        owner = r.owner;
        to = r.to;
        amount = r.amount;
        executeAfter = r.executeAfter;

        if (owner == address(0)) {
            status = DelayRequestStatus.NONE;
            secondsRemaining = 0;
            return (owner, to, amount, executeAfter, status, secondsRemaining);
        }

        if (r.executed) {
            status = DelayRequestStatus.EXECUTED;
            secondsRemaining = 0;
        } else if (r.canceled) {
            status = DelayRequestStatus.CANCELED;
            secondsRemaining = 0;
        } else if (r.executeAfter + expires < block.timestamp) {
            status = DelayRequestStatus.EXPIRED;
            secondsRemaining = 0;
        } else if (block.timestamp >= r.executeAfter) {
            status = DelayRequestStatus.EXECUTABLE;
            secondsRemaining = 0;
        } else {
            status = DelayRequestStatus.PENDING;
            secondsRemaining = r.executeAfter - block.timestamp;
        }
    }

    function getNextDelayRequestId(QueueKey key) external view returns (uint256){
        return _requestId(key);
    }

    function getDelayNonce(address owner) external view returns (uint256){
        return sigNonces[owner];
    }

    function _openDelayQueueList(QueueKey key, address owner) internal view returns (uint256[] memory){
        return openIds[key][owner];
    }

    function _verifyDelayQueueSig(
        bytes32 typehash,
        address owner,
        address newWallet,
        uint256 deadline,
        bytes calldata sig
    ) internal {
        if (block.timestamp > deadline) revert AITradeHubSignExpError();

        uint256 nonce = sigNonces[owner];

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(typehash, owner, newWallet, nonce, deadline))
        );
        address recovered = digest.recover(sig);
        if (recovered != owner) revert AITradeHubSignInvalidError();
        sigNonces[owner]++;
    }

    function _requireRequestExecutable(QueueKey key, uint256 id) view internal {
        DelayRequest storage r = delayRequests[key][id];

        if (r.owner == address(0)) revert AITradeHubDataInvalidError();
        if (r.owner != msg.sender) revert AITradeHubPermissionDeniedError();
        if (r.executed) revert AITradeHubHubExecutedError();
        if (r.canceled) revert AITradeHubCanceledError();
        if (block.timestamp < r.executeAfter) revert AITradeHubTooEarlyError();
        if (r.executeAfter + expires < block.timestamp) revert AITradeHubExpiredError();
    }

    function _requireRequestCancelable(QueueKey key, uint256 id) view internal {
        DelayRequest storage r = delayRequests[key][id];
        address owner = r.owner;
        if (owner == address(0)) revert AITradeHubDataInvalidError();
        if (owner != msg.sender) revert AITradeHubPermissionDeniedError();
        if (r.executed) revert AITradeHubHubExecutedError();
        if (r.canceled) revert AITradeHubCanceledError();
    }

    function _requireOpenDelayRequestNotFull(QueueKey key, address owner) view internal {
        if (openIds[key][owner].length >= MAX_OPEN_REQUESTS) revert AITradeHubExceedRequest();
    }

    function _addOpenDelayQueue(QueueKey key, address owner, uint256 id) internal {
        openIds[key][owner].push(id);
        indexPlusOne[key][id] = openIds[key][owner].length;
    }

    function _removeOpenDelayQueue(QueueKey key, address owner, uint256 id) internal {
        uint256 p = indexPlusOne[key][id];
        if (p == 0) return;
        uint256 idx = p - 1;
        uint256[] storage arr = openIds[key][owner];
        uint256 lastId = arr[arr.length - 1];
        if (idx != arr.length - 1) {
            arr[idx] = lastId;
            indexPlusOne[key][lastId] = idx + 1;
        }
        arr.pop();
        indexPlusOne[key][id] = 0;
    }

    function _requestId(QueueKey key) internal view returns (uint256){
        return requestId[key];
    }

    function _nextRequestId(QueueKey key) internal returns (uint256){
        return requestId[key]++;
    }


}