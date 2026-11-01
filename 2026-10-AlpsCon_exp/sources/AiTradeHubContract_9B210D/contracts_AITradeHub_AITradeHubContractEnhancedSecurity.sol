//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeERC20} from "../math/SafeERC20.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AiTradeHubContractDelayQueueBase} from "./AITradeHubContractDelayQueueBase.sol";


abstract contract AiTradeHubContractEnhancedSecurity is AITradeHubContractCommon,AiTradeHubContractDelayQueueBase {

    event AITradeHubDisableEnhancedSecurityDelayedRequested(uint256 indexed id, address indexed owner, uint64 executeAfter);
    event AITradeHubDisableEnhancedSecurityDelayedCanceled(uint256 indexed id, address indexed owner);
    event AITradeHubDisableEnhancedSecurityDelayedExecuted(uint256 indexed id, address indexed owner);

    error AITradeHubEnhancedSecurityNotEnable();

    function enableEnhancedSecurityMode() external onlyVerified {
        address owner = msg.sender;
        if (_openDelayQueueList(QueueKey.ENHANCED_SECURITY, owner).length > 0)
            revert AITradeHubExceedRequest();
        _setEnhancedSecurityMode(msg.sender, true);
    }

    function requestDisableEnhancedSecurityDelayed() external onlyVerified nonReentrant
    {
        address owner = msg.sender;

        // prevent spam
       _requireOpenDelayRequestNotFull(QueueKey.ENHANCED_SECURITY,owner);

        if (!_isEnhancedSecurityMode(owner)) revert AITradeHubEnhancedSecurityNotEnable();

        uint256 id = _nextRequestId(QueueKey.ENHANCED_SECURITY);
        delayRequests[QueueKey.ENHANCED_SECURITY][id] = DelayRequest({
            owner: owner,
            to:address(0),
            amount:0,
            executeAfter: uint64(block.timestamp) + delay,
            executed: false,
            canceled: false
        });

        _addOpenDelayQueue(QueueKey.ENHANCED_SECURITY, owner, id);

        emit AITradeHubDisableEnhancedSecurityDelayedRequested(id, owner, uint64(block.timestamp) + delay);
    }

    function cancelDisableEnhancedSecurityDelayed(uint256 id) external onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.ENHANCED_SECURITY][id];
        address owner = r.owner;

        _requireRequestCancelable(QueueKey.ENHANCED_SECURITY, id);
        r.canceled = true;

        _removeOpenDelayQueue(QueueKey.ENHANCED_SECURITY, owner, id);

        emit AITradeHubDisableEnhancedSecurityDelayedCanceled(id, owner);
    }

    function executeDisableEnhancedSecurityDelayed(uint256 id) external onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.ENHANCED_SECURITY][id];
        _requireRequestExecutable(QueueKey.ENHANCED_SECURITY,id);

        // disable enhanced security
        _setEnhancedSecurityMode(r.owner, false);

        r.executed = true;
        _removeOpenDelayQueue(QueueKey.ENHANCED_SECURITY, r.owner, id);

        emit AITradeHubDisableEnhancedSecurityDelayedExecuted(id, r.owner);
    }


    // Implement on AITradeHubContract
    function _setEnhancedSecurityMode(address user, bool enable) internal virtual;
}