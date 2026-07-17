// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {OwnerHinkal} from "./OwnerHinkal.sol";
import {Dimensions} from "./types/Dimensions.sol";
import {IVerifierFacade} from "./types/IVerifierFacade.sol";
import {IVerifier} from "./types/IVerifier.sol";

///@title A Facade pattern for zk proof Verifiers
contract VerifierFacade is IVerifierFacade, OwnerHinkal {
    mapping(uint256 => IVerifier) public verifierMap;

    function registerVerifiers(
        uint256[] calldata verifierIds,
        address[] calldata verifierAddresses
    ) external onlyOwner {
        for (uint i = 0; i < verifierIds.length; i++) {
            verifierMap[verifierIds[i]] = IVerifier(verifierAddresses[i]);
            emit VerifierRegistered(verifierIds[i], verifierAddresses[i]);
        }
    }

    function removeVerifier(uint256 verifierId) external onlyOwner {
        delete verifierMap[verifierId];
        emit VerifierRemoved(verifierId);
    }

    function buildVerifierId(
        Dimensions calldata dimensions,
        uint256 externalActionId
    ) public pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encode(
                        dimensions.tokenNumber,
                        dimensions.nullifierAmount,
                        dimensions.outputAmount,
                        externalActionId
                    )
                )
            );
    }

    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] memory input,
        uint256 verifierId
    ) internal view returns (bool) {
        IVerifier verifier = verifierMap[verifierId];
        require(
            address(verifier) != address(0),
            "Cannot find appropriate verifier"
        );
        return verifier.verifyProof(a, b, c, input, verifierId);
    }
}
