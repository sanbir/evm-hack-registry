//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";
import {AiTradeHubContractDelayQueueBase} from "./AITradeHubContractDelayQueueBase.sol";


abstract contract AiTradeHubContractMigrateWallet is AITradeHubContractCommon, AiTradeHubContractDelayQueueBase {

    event AITradeHubMigrateWalletDelayedRequested(uint256 indexed id, address indexed owner, address newWallet, uint64 executeAfter);
    event AITradeHubMigrateWalletDelayedCanceled(uint256 indexed id, address indexed owner);
    event AITradeHubMigrateWalletDelayedExecuted(uint256 indexed id, address indexed owner, address newWallet);

    bytes32 internal constant MIGRATE_WALLET_WITH_SIGN_TYPEHASH = keccak256("MigrateWalletSig(address owner,address newWallet,uint256 nonce,uint256 deadline)");


    function migrateWallet(address newWallet) external onlyVerified {
        address owner = msg.sender;
        if (_isEnhancedSecurityMode(owner)) {
            _requestMigrateWalletDelayed(owner, newWallet);
            return;
        }
        _migrateWallet(owner, newWallet);
    }

    function migrateWalletWithSig(address owner, address newWallet, uint256 deadline, bytes calldata sig) external onlyOwner {
        _verifyDelayQueueSig(MIGRATE_WALLET_WITH_SIGN_TYPEHASH, owner, newWallet, deadline, sig);

        _migrateWallet(owner, newWallet);
    }

    function _requestMigrateWalletDelayed(address owner, address newWallet) internal{
        // prevent spam
        _requireOpenDelayRequestNotFull(QueueKey.MIGRATE_WALLET, owner);

        _requireMigrateWalletPossible(owner, newWallet);

        uint256 id = _nextRequestId(QueueKey.MIGRATE_WALLET);
        delayRequests[QueueKey.MIGRATE_WALLET][id] = DelayRequest({
            owner: owner,
            to: newWallet,
            amount:0,
            executeAfter: uint64(block.timestamp) + delay,
            executed: false,
            canceled: false
        });

        _addOpenDelayQueue(QueueKey.MIGRATE_WALLET, owner, id);

        emit AITradeHubMigrateWalletDelayedRequested(id, owner, newWallet, uint64(block.timestamp) + delay);
    }

    function cancelMigrateWalletDelayed(uint256 id) external onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.MIGRATE_WALLET][id];
        address owner = r.owner;
        _requireRequestCancelable(QueueKey.MIGRATE_WALLET, id);

        r.canceled = true;
        _removeOpenDelayQueue(QueueKey.MIGRATE_WALLET, r.owner, id);

        emit AITradeHubMigrateWalletDelayedCanceled(id, owner);
    }

    function executeMigrateWalletDelayed(uint256 id) external nonReentrant onlyVerified {
        DelayRequest storage r = delayRequests[QueueKey.MIGRATE_WALLET][id];
        _requireRequestExecutable(QueueKey.MIGRATE_WALLET,id);
        r.executed = true;

        _migrateWallet(r.owner, r.to);
        _removeOpenDelayQueue(QueueKey.MIGRATE_WALLET, r.owner, id);

        emit AITradeHubMigrateWalletDelayedExecuted(id, r.owner, r.to);
    }

    // Implement on AITradeHubContract
    function _requireMigrateWalletPossible(address owner, address newWallet) internal view virtual;

    function _migrateWallet(address owner, address newWallet) internal virtual;
}