//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {AiTradeHubContractDelayQueueBase} from "./AITradeHubContractDelayQueueBase.sol";


abstract contract AiTradeHubContractWithdrawFund is AITradeHubContractCommon, AiTradeHubContractDelayQueueBase {

    event AITradeHubWithdrawFundsDelayedRequested(uint256 indexed id, address indexed owner, uint256 amount, uint64 executeAfter);
    event AITradeHubWithdrawFundsDelayedCanceled(uint256 indexed id, address indexed owner);
    event AITradeHubWithdrawFundsDelayedExecuted(uint256 indexed id, address indexed owner, uint256 amount);


    address internal transferToken;

    constructor(address token){
        transferToken = token;
    }

    function withdrawFunds(uint256 amount) external onlyVerified nonReentrant{
        if (amount == 0) revert AITradeHubAmountInvalidError();
        address user = msg.sender;
        if (_isEnhancedSecurityMode(user)) {
            _requestWithdrawFundsDelayed(amount);
            return;
        }
        _updateUserProfitCheckpoint(user);
        _transfer(transferToken, user, user, amount);
    }

    function _requestWithdrawFundsDelayed(uint256 amount) internal returns (uint256 id){
        address owner = msg.sender;

        // prevent spam
        _requireOpenDelayRequestNotFull(QueueKey.WITHDRAW_FUNDS, owner);

        _requireWithdrawFundsPossible(owner, amount);

        id = _nextRequestId(QueueKey.WITHDRAW_FUNDS);
        delayRequests[QueueKey.WITHDRAW_FUNDS][id] = DelayRequest({
            owner: owner,
            to:address(0),
            amount: amount,
            executeAfter: uint64(block.timestamp) + delay,
            executed: false,
            canceled: false
        });

        _addOpenDelayQueue(QueueKey.WITHDRAW_FUNDS, owner, id);

        emit AITradeHubWithdrawFundsDelayedRequested(id, owner, amount, uint64(block.timestamp) + delay);
    }

    function cancelWithdrawFundsDelayed(uint256 id) external onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.WITHDRAW_FUNDS][id];
        address owner = r.owner;
        _requireRequestCancelable(QueueKey.WITHDRAW_FUNDS, id);

        r.canceled = true;
        _removeOpenDelayQueue(QueueKey.WITHDRAW_FUNDS, r.owner, id);

        emit AITradeHubWithdrawFundsDelayedCanceled(id, owner);
    }


    function executeWithdrawFundsDelayed(uint256 id) external onlyVerified nonReentrant {
        DelayRequest storage r = delayRequests[QueueKey.WITHDRAW_FUNDS][id];
        _requireRequestExecutable(QueueKey.WITHDRAW_FUNDS,id);
        _requireWithdrawFundsPossible(r.owner, r.amount);

        r.executed = true;
        _removeOpenDelayQueue(QueueKey.WITHDRAW_FUNDS, r.owner, id);

        _transfer(transferToken, r.owner, r.owner, r.amount);

        emit AITradeHubWithdrawFundsDelayedExecuted(id, r.owner, r.amount);
    }

    // Implement on AITradeHubContract
    function _requireWithdrawFundsPossible(address user, uint256 amount) internal view virtual;

    function _updateUserProfitCheckpoint(address user) internal virtual;

    function _transfer(address tokenAddress, address from, address to, uint256 amount) internal virtual;
}