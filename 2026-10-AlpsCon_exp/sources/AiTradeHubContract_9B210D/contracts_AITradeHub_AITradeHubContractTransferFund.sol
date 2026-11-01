//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {AiTradeHubContractDelayQueueBase} from "./AITradeHubContractDelayQueueBase.sol";


abstract contract AiTradeHubContractTransferFund is AITradeHubContractCommon, AiTradeHubContractDelayQueueBase {

    event AITradeHubTransferFundsDelayedRequested(uint256 indexed id, address indexed owner, address to, uint256 amount, uint64 executeAfter);
    event AITradeHubTransferFundsDelayedCanceled(uint256 indexed id, address indexed owner);
    event AITradeHubTransferFundsDelayedExecuted(uint256 indexed id, address indexed owner, address to, uint256 amount);


    function transferFunds(address to, uint256 amount) external onlyVerified {
        if (amount == 0) revert AITradeHubAmountInvalidError();
        address owner = msg.sender;
        if (_isEnhancedSecurityMode(owner)) {
            _requestTransferFundsDelayed(owner, to, amount);
            return;
        }
        _transferFunds(owner, to, amount);
    }

    function _requestTransferFundsDelayed(address owner, address to, uint256 amount) internal {

        // prevent spam
        _requireOpenDelayRequestNotFull(QueueKey.TRANSFER_FUNDS, owner);

        _requireTransferFundsPossible(owner, amount);

        uint256 id = _nextRequestId(QueueKey.TRANSFER_FUNDS);
        delayRequests[QueueKey.TRANSFER_FUNDS][id] = DelayRequest({
            owner: owner,
            to: to,
            amount: amount,
            executeAfter: uint64(block.timestamp) + delay,
            executed: false,
            canceled: false
        });

        _addOpenDelayQueue(QueueKey.TRANSFER_FUNDS, owner, id);

        emit AITradeHubTransferFundsDelayedRequested(id, owner, to, amount, uint64(block.timestamp) + delay);
    }

    function cancelTransfersFundsDelayed(uint256 id) external onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.TRANSFER_FUNDS][id];
        address owner = r.owner;
        _requireRequestCancelable(QueueKey.TRANSFER_FUNDS, id);

        r.canceled = true;
        _removeOpenDelayQueue(QueueKey.TRANSFER_FUNDS, r.owner, id);

        emit AITradeHubTransferFundsDelayedCanceled(id, owner);
    }

    function executeTransferFundsDelayed(uint256 id) external nonReentrant onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.TRANSFER_FUNDS][id];
        _requireRequestExecutable(QueueKey.TRANSFER_FUNDS,id);

        r.executed = true;
        _transferFunds(r.owner, r.to, r.amount);
        _removeOpenDelayQueue(QueueKey.TRANSFER_FUNDS, r.owner, id);

        emit AITradeHubTransferFundsDelayedExecuted(id, r.owner, r.to, r.amount);
    }

    // Implement on AITradeHubContract
    function _requireTransferFundsPossible(address owner, uint256 amount) internal view virtual;

    function _transferFunds(address owner, address to, uint256 amount) internal virtual;
}