// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IHinkalHelper} from "./IHinkalHelper.sol";

interface IHinkalBase {
    event NewCommitment(
        uint256 commitment,
        int256 index,
        bytes encryptedOutput
    );
    event Nullified(uint256 nullifier);

    event NewTransaction(
        address sender,
        uint256 timestamp,
        address erc20TokenAddress,
        int256 publicAmount
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

    event NewUtxo(
        uint256 amount,
        address erc20Address,
        uint256 randomization,
        uint256 stealthAddress,
        uint256 timeStamp,
        uint256 tokenId
    );

    event NewApprovedUtxo(
        address approveTo,
        address tokenAddress,
        int256 amount,
        uint256 inHinkalAddress
    );

    function setHinkalHelper(address _hinkalHelper) external;

    function hinkalHelper() external view returns (IHinkalHelper);
}
