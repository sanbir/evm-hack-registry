// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

abstract contract HinkalInLogicMetadataParser {
    struct ParsedInLogicMetadata {
        bytes signature;
        uint256 deadline;
        address[] erc20TokenAddresses;
        bytes externalCallData;
    }

    function parseInLogicMetadata(
        bytes memory externalMetadata
    ) internal pure returns (ParsedInLogicMetadata memory result) {
        (
            bytes memory signature,
            uint256 deadline,
            address[] memory erc20TokenAddresses,
            bytes memory externalCallData
        ) = abi.decode(externalMetadata, (bytes, uint256, address[], bytes));
        result.signature = signature;
        result.deadline = deadline;
        result.erc20TokenAddresses = erc20TokenAddresses;
        result.externalCallData = externalCallData;
    }
}
