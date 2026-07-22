// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

interface ISodiumAuth {
    function verifyProof(
        bytes32 messageHash,
        bytes calldata proof
    ) external view returns (bool currentOperators);
}
