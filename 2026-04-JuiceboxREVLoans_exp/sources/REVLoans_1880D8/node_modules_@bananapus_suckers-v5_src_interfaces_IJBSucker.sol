// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBTokens} from "@bananapus/core-v5/src/interfaces/IJBTokens.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBAddToBalanceMode} from "../enums/JBAddToBalanceMode.sol";
import {JBSuckerState} from "../enums/JBSuckerState.sol";
import {JBClaim} from "../structs/JBClaim.sol";
import {JBInboxTreeRoot} from "../structs/JBInboxTreeRoot.sol";
import {JBOutboxTree} from "../structs/JBOutboxTree.sol";
import {JBRemoteToken} from "../structs/JBRemoteToken.sol";
import {JBTokenMapping} from "../structs/JBTokenMapping.sol";
import {JBMessageRoot} from "../structs/JBMessageRoot.sol";

// @notice The minimal interface for a sucker contract.
interface IJBSucker is IERC165 {
    event Claimed(
        address beneficiary,
        address token,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        uint256 index,
        bool autoAddedToBalance,
        address caller
    );
    event InsertToOutboxTree(
        address indexed beneficiary,
        address indexed token,
        bytes32 hashed,
        uint256 index,
        bytes32 root,
        uint256 projectTokenCount,
        uint256 terminalTokenAmount,
        address caller
    );
    event NewInboxTreeRoot(address indexed token, uint64 nonce, bytes32 root, address caller);
    event RootToRemote(bytes32 indexed root, address indexed token, uint256 index, uint64 nonce, address caller);

    function MESSENGER_BASE_GAS_LIMIT() external view returns (uint32);
    function MESSENGER_ERC20_MIN_GAS_LIMIT() external view returns (uint32);

    function ADD_TO_BALANCE_MODE() external view returns (JBAddToBalanceMode);
    function DIRECTORY() external view returns (IJBDirectory);
    function TOKENS() external view returns (IJBTokens);

    function deployer() external view returns (address);
    function peer() external view returns (address);
    function projectId() external view returns (uint256);

    function amountToAddToBalanceOf(address token) external view returns (uint256 amount);
    function inboxOf(address token) external view returns (JBInboxTreeRoot memory);
    function isMapped(address token) external view returns (bool);
    function outboxOf(address token) external view returns (JBOutboxTree memory);
    function peerChainId() external view returns (uint256 chainId);
    function remoteTokenFor(address token) external view returns (JBRemoteToken memory);
    function state() external view returns (JBSuckerState);

    function addOutstandingAmountToBalance(address token) external;
    function claim(JBClaim[] calldata claims) external;
    function claim(JBClaim calldata claimData) external;
    function mapToken(JBTokenMapping calldata map) external payable;
    function mapTokens(JBTokenMapping[] calldata maps) external payable;
    function prepare(
        uint256 projectTokenAmount,
        address beneficiary,
        uint256 minTokensReclaimed,
        address token
    )
        external;
    function toRemote(address token) external payable;
}
