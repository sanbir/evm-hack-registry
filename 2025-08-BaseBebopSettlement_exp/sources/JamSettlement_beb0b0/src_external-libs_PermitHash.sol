// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../interfaces/IPermit2.sol";

// from PermitHash.sol in Permit2
// https://github.com/Uniswap/permit2/blob/main/src/libraries/PermitHash.sol
library PermitHash {

    bytes32 private constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    string private constant _PERMIT_BATCH_WITNESS_TRANSFER_FROM_TYPEHASH_STUB = "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";

    function hashWithWitness(
        IPermit2.PermitBatchTransferFrom memory permit,
        bytes32 witness,
        string memory witnessTypeString,
        address spender
    ) internal pure returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(_PERMIT_BATCH_WITNESS_TRANSFER_FROM_TYPEHASH_STUB, witnessTypeString));

        uint256 numPermitted = permit.permitted.length;
        bytes32[] memory tokenPermissionHashes = new bytes32[](numPermitted);

        for (uint256 i = 0; i < numPermitted; ++i) {
            tokenPermissionHashes[i] = _hashTokenPermissions(permit.permitted[i]);
        }

        return keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(tokenPermissionHashes)),
                spender,
                permit.nonce,
                permit.deadline,
                witness
            )
        );
    }

    function _hashTokenPermissions(IPermit2.TokenPermissions memory permitted) private pure returns (bytes32){
        return keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permitted));
    }
}