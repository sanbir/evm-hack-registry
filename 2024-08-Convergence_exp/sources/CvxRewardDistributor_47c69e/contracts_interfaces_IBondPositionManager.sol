// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IBondStruct.sol";
import "./IBondLogo.sol";
import "./IBondDepository.sol";

interface IBondPositionManager {
    function bondDepository() external view returns (IBondDepository);

    function getTokenIdsForWallet(address _wallet) external view returns (uint256[] memory);

    function bondPerTokenId(uint256 tokenId) external view returns (uint256);

    // Deposit Principle token in Treasury through Bond contract
    function mintOrCheck(uint256 bondId, uint256 tokenId, address receiver) external returns (uint256);

    function burn(uint256 tokenId) external;

    function unlockingTimestampPerToken(uint256 tokenId) external view returns (uint256);

    function logoInfo(uint256 tokenId) external view returns (IBondLogo.LogoInfos memory);

    function checkTokenRedeem(uint256[] calldata tokenIds, address receiver) external view;
}
