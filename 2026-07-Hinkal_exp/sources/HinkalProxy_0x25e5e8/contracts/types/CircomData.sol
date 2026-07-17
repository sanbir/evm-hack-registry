// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.6;

import {StealthAddressStructure} from "./StealthAddressStructure.sol";
import {SignatureData} from "./IAccessToken.sol";

// enum HinkalLogicAction {
//     NONE, // = 0
//     ONLY_APPROVAL, // = 1
//     RELEASE_BUFFER // = 2
//     EXECUTE, // = 3
// }

struct UseApprovalUTXOData {
    int256[] approvalChanges;
    address[] externalApprovalAddresses;
    uint256[] conversionInHinkalAddress;
}

struct HinkalLogicArgs {
    uint256 hinkalLogicAction;
    uint256 inHinkalAddress;
    int256[] executeApprovalChanges;
    bool doPreTxApproval;
    UseApprovalUTXOData[] useApprovalUtxoData;
}

struct FeeStructure {
    address feeToken;
    uint256 flatFee;
    uint256 variableRate; // measured in beeps = 0.01 of 1%
}

struct CircomData {
    uint256 rootHashHinkal;
    address[] erc20TokenAddresses;
    uint256[] tokenIds;
    int256[] amountChanges;
    bool[] onChainCreation;
    int256[] slippageValues;
    uint256[][] inputNullifiers;
    uint256[][] outCommitments;
    bytes[][] encryptedOutputs;
    FeeStructure feeStructure;
    uint256 timeStamp;
    StealthAddressStructure stealthAddressStructure;
    uint256 rootHashAccessToken;
    uint256 calldataHash;
    uint16 publicSignalCount;
    address relay;
    address externalAddress;
    uint256 externalActionId;
    bytes externalActionMetadata;
    HinkalLogicArgs hinkalLogicArgs;
    HookData hookData;
    SignatureData signatureData;
    address originalSender;
}

struct HookData {
    address preHookContract;
    address hookContract;
    bytes preHookMetadata;
    bytes postHookMetadata;
}
