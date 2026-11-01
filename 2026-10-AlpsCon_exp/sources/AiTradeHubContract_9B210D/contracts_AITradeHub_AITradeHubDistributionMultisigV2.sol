// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {AITradeHubContractCommon} from "./AITradeHubContractCommon.sol";


abstract contract AITradeHubDistributionMultisigV2 is AITradeHubContractCommon {
    // -------------------------
    // Config
    // -------------------------
    struct MultisigConfig {
        uint256 requiredConfirmations;   // e.g., 2 for 2-of-3
        uint64  minDelay;                // seconds to wait after enough confirms
        uint64  ttl;                     // proposal expires after this many seconds from creation (0 = never)
    }

    MultisigConfig public msig;

    // signer set
    address[] private _signers;
    mapping(address => bool) public isSigner;

    // -------------------------
    // Proposals
    // -------------------------
    struct Proposal {
        int256  amount;
        address proposer;
        bool    executed;
        bool    cancelled;
        uint64  createdAt;
        uint64  readyAt;
        uint128 confirmCount;
        mapping(address => bool) confirmed; // signer => hasConfirmed
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;

    // -------------------------
    // Events
    // -------------------------
    event SignerAdded(address signer);
    event SignerRemoved(address signer);
    event ThresholdUpdated(uint256 required);
    event TimelockUpdated(uint64 minDelay, uint64 ttl);

    event ProposalCreated(uint256 indexed id, address indexed proposer, int256 amount);
    event ProposalConfirmed(uint256 indexed id, address indexed signer, uint256 confirmCount);
    event ProposalRevoked(uint256 indexed id, address indexed signer, uint256 confirmCount);
    event ProposalCancelled(uint256 indexed id, address indexed caller);
    event ProposalExecutable(uint256 indexed id, uint64 readyAt);
    event ProposalExecuted(uint256 indexed id, address indexed executor, int256 amount);

    // -------------------------
    // Access
    // -------------------------
    modifier onlySigner() {
        if(!isSigner[msg.sender]) revert AITradeHubPermissionDeniedError();
        _;
    }

    // -------------------------
    // Install / configure
    // -------------------------
    function _initMultisig(address[] memory signers, uint256 requiredConfirmations, uint64 minDelay, uint64 ttl) internal {
        if(_signers.length > 0) revert AITradeHubPermissionDeniedError();
        if(signers.length == 0) revert AITradeHubDataInvalidError();
        if(requiredConfirmations == 0 || requiredConfirmations > signers.length) revert AITradeHubDataInvalidError();

        for (uint256 i = 0; i < signers.length; i++) {
            address s = signers[i];
            if(s == address(0)) revert AITradeHubAddressInvalidError();
            if(isSigner[s]) revert AITradeHubAddressInvalidError();
            isSigner[s] = true;
            _signers.push(s);
            emit SignerAdded(s);
        }
        msig = MultisigConfig({
            requiredConfirmations: requiredConfirmations,
            minDelay: minDelay,
            ttl: ttl
        });
        emit ThresholdUpdated(requiredConfirmations);
        emit TimelockUpdated(minDelay, ttl);
    }

    /// Create a new distribution proposal (amount can be negative for loss booking).
    function proposeDistribution(int256 amount) external onlySigner returns (uint256 id) {
        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.amount = amount;
        p.proposer = msg.sender;
        p.createdAt = uint64(block.timestamp);
        // No confirmations yet
        emit ProposalCreated(id, msg.sender, amount);
    }

    /// Signer confirms a proposal.
    function confirmProposal(uint256 id) external onlySigner {
        Proposal storage p = _mustExist(id);
        if(p.executed || p.cancelled) revert AITradeHubSignInvalidError();
        if(_expired(p)) revert AITradeHubSignExpError();
        if(p.confirmed[msg.sender]) revert AITradeHubSignInvalidError();

        p.confirmed[msg.sender] = true;
        unchecked { p.confirmCount += 1; }
        emit ProposalConfirmed(id, msg.sender, p.confirmCount);

        if (p.confirmCount >= msig.requiredConfirmations && p.readyAt == 0) {
            uint64 ready = uint64(block.timestamp) + msig.minDelay;
            p.readyAt = ready;
            emit ProposalExecutable(id, ready);
        }
    }

    /// Proposer or owner can cancel before execution (or after expiry).
    function cancelProposal(uint256 id) external {
        Proposal storage p = _mustExist(id);
        if(p.executed || p.cancelled) revert AITradeHubSignInvalidError();
        if(msg.sender != p.proposer) revert AITradeHubPermissionDeniedError();
        p.cancelled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    /// Execute after threshold met, delay passed, and not expired.
    function executeProposal(uint256 id) external nonReentrant onlySigner {
        Proposal storage p = _mustExist(id);
        if(p.executed || p.cancelled) revert AITradeHubSignInvalidError();
        if(p.confirmCount < msig.requiredConfirmations) revert AITradeHubPermissionDeniedError();
        if(p.readyAt == 0 || block.timestamp < p.readyAt) revert AITradeHubPermissionDeniedError();
        if(_expired(p)) revert AITradeHubSignExpError();

        p.executed = true;

        // >>> Call AI Trade Hub contract's internal distribution:
        _distributeServiceResults(p.amount);

        emit ProposalExecuted(id, msg.sender, p.amount);
    }

    // -------------------------
    // Views / helpers
    // -------------------------

    function getSigners() external view returns (address[] memory) {
        return _signers;
    }

    function getProposal(uint256 id)
    external
    view
    returns (
        int256 amount,
        address proposer,
        uint64 createdAt,
        uint64 readyAt,
        bool executed,
        bool cancelled,
        uint256 confirmCount
    )
    {
        Proposal storage p = _proposals[id];
        if(p.proposer == address(0)) revert AITradeHubDataInvalidError();
        return (p.amount, p.proposer, p.createdAt, p.readyAt, p.executed, p.cancelled, p.confirmCount);
    }

    // -------------------------
    // Internal utils
    // -------------------------
    function _mustExist(uint256 id) internal view returns (Proposal storage p) {
        p = _proposals[id];
        if(p.proposer == address(0)) revert AITradeHubDataInvalidError();
    }

    function _expired(Proposal storage p) internal view returns (bool) {
        if (msig.ttl == 0) return false;
        return (block.timestamp > uint256(p.createdAt) + uint256(msig.ttl));
    }

    // Implement on AITradeHubContract
    function _distributeServiceResults(int256 amount) internal virtual;
}