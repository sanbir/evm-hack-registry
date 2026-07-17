// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import "./IMerkle.sol";
import "./AxelarInfo.sol";

struct SignatureData {
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 accessKey;
    uint256 nonce;
    address ethereumAddress;
}

struct AccessTokenWithAddress {
    uint256 accessToken;
    address ethAddress;
}

interface IAccessToken {
    event NewAccessKeyAdded(
        uint256 accessKey,
        uint256 index,
        address senderAddress
    );
    event MintingFeeChanged(uint256 newMintingFee);
    event AccessKeyBlacklisted(uint256 blacklistedAccessKey);
    event AddressBlacklisted(address blacklistedAddress);
    event AddressRemovedFromBlacklist(address addressToRestore);
    event AccessKeyMigrationReceived(uint256 accessKey, string sourceChain);
    event CrossChainAccessTokenRegistryChange(
        string sourceChain,
        address sourceAddress
    );

    struct CrossChainAccessTokenRegistryUpdate {
        string sourceChain;
        address sourceAddress;
    }

    function addToken(SignatureData calldata signatureData) external;

    function hasToken(uint256 accessKey) external view returns (bool);

    function blacklistAccessKey(uint256 accessKey, uint256 index) external;

    function blacklistAddress(address _address) external;

    function removeAddressFromBlacklist(address addressToRestore) external;

    function setAxelarGasService(address _gasService) external;

    function addTokenCrossChain(
        SignatureData calldata signatureData,
        AxelarCapsule calldata capsule
    ) external payable;

    function migrateAccessToken(
        AxelarCapsule calldata capsule,
        uint256 accessKey
    ) external payable;

    function registerCheck(address sender) external view;

    function checkForRootHash(
        uint256 rootHashAccessToken,
        address sender
    ) external view returns (bool);
}
