// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMOSV3 {
    enum ChainType {
        NULL,
        EVM,
        NEAR
    }

    enum MessageType {
        CALLDATA,
        MESSAGE
    }

    // @notice This is the configuration you need across the chain.
    // @param relay - When it is true, the relay chain is required to perform a special execution to continue across the chain.
    // @param msgType - Different execution patterns of messages across chains.
    // @param target - The contract address of the target chain.
    // @param payload - Cross-chain data.
    // @param gasLimit - The gasLimit allowed to be consumed by an operation performed on the target chain.
    // @param value - Collateral value cross-chain, currently not supported, default is 0.
    struct MessageData {
        bool relay;
        MessageType msgType;
        bytes target;
        bytes payload;
        uint256 gasLimit;
        uint256 value;
    }

    // @notice Gets the fee to cross to the target chain.
    // @param toChain - Target chain chainID.
    // @param feeToken - Token address that supports payment fee,if it's native, it's address(0).
    // @param gasLimit - The gasLimit allowed to be consumed by an operation performed on the target chain.
    function getMessageFee(
        uint256 toChain,
        address feeToken,
        uint256 gasLimit
    ) external view returns (uint256, address);

    function getOrderStatus(
        uint256 _chainId,
        uint256 _blockNum,
        bytes32 _orderId
    ) external view returns (bool exists, bool verifiable, uint256 nodeType);

    // @notice Initiate cross-chain transactions. Generate cross-chain logs.
    // @param toChain - Target chain chainID.
    // @param messageData - Structure MessageData encoding.
    // @param feeToken - In what Token would you like to pay the fee.
    function transferOut(
        uint256 toChain,
        bytes memory messageData,
        address feeToken
    ) external payable returns (bytes32);

    // @notice Add remote address permission.
    // @param fromChain - The chain id of the source chain.
    // @param fromAddress - The call address of the source chain.
    // @param tag - Permission,false: revoke permission.
    function addRemoteCaller(uint256 fromChain, bytes memory fromAddress, bool tag) external;

    // @notice Query whether the contract has execution permission.
    // @param targetAddress - The target address.
    // @param fromChain - The chain id of the source chain.
    // @param fromAddress - The call address of the source chain.
    function getExecutePermission(
        address targetAddress,
        uint256 fromChain,
        bytes memory fromAddress
    ) external view returns (bool);

    event mapMessageOut(
        uint256 indexed fromChain,
        uint256 indexed toChain,
        bytes32 orderId,
        bytes fromAddrss,
        bytes callData
    );

    event mapMessageIn(
        uint256 indexed fromChain,
        uint256 indexed toChain,
        bytes32 orderId,
        bytes fromAddrss,
        bytes callData,
        bool result,
        bytes reason
    );
}
