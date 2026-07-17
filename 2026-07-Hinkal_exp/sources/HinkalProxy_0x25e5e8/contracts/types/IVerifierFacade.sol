// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;
import "./IVerifier.sol";
import "./Dimensions.sol";

interface IVerifierFacade {
    event VerifierRegistered(uint256 verifierId, address verifierAddress);
    event VerifierRemoved(uint256 verifierId);

    function registerVerifiers(
        uint256[] calldata verifierIds,
        address[] calldata verifierAddresses
    ) external;

    function removeVerifier(uint256 verifierId) external;

    function buildVerifierId(
        Dimensions calldata dimensions,
        uint256 externalActionId
    ) external pure returns (uint256);
}
