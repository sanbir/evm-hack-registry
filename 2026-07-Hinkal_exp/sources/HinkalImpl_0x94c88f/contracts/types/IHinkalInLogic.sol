// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import {CircomData} from "./CircomData.sol";
import {ApprovedUtxo, UTXO} from "./UTXO.sol";
import {StealthAddressStructure} from "./StealthAddressStructure.sol";

struct FormUtxosAndCheckSpendingsArgs {
    CircomData circomData;
    uint256[] oldBalances;
    uint256[] newBalances;
    uint256[] oldAllowances;
    uint256[] newAllowances;
}

struct TokenWithAmountAndId {
    address erc20Address;
    uint256 amount;
    uint256 tokenId;
}

interface IHinkalInLogic {
    event NewApprovedUtxo(
        address approveTo,
        address tokenAddress,
        int256 amount,
        uint256 inHinkalAddress
    );

    event NewBufferEntry(
        address approvalTarget,
        address tokenAddress,
        uint256 amount,
        uint256 inHinkalAddress
    );

    event BufferReleased(
        address approvalTarget,
        address tokenAddress,
        uint256 inHinkalAddress
    );

    function getApprovalsBufferValue(
        address approveTo,
        address tokenAddress,
        uint256 inHinkalAddress
    ) external returns (uint256);

    function inHinkalTransact(
        CircomData calldata circomData,
        int256[] memory approvalChangesPerToken
    ) external payable returns (UTXO[] memory);

    function getInteractionApprovals(
        address interaction
    ) external view returns (ApprovedUtxo[] memory);

    function bufferApprovals(
        address[] calldata approvalTargets,
        uint256[][] calldata indexes
    ) external;

    function handleApprovalUtxos(
        CircomData calldata circomData
    ) external returns (int256[] memory);

    function handleRunExternalAction(
        CircomData memory circomDataMemory,
        int256[] memory approvalChangesPerToken
    ) external returns (UTXO[] memory);

    function handleProoflessDeposit(
        address[] calldata erc20Addresses,
        uint256[] calldata amounts,
        uint256[] calldata tokenIds,
        StealthAddressStructure[] calldata stealthAddressStructures
    ) external payable returns (UTXO[] memory utxoArray);
}
