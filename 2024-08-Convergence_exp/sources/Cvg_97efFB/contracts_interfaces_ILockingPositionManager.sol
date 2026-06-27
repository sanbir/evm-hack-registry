// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./ILockingLogo.sol";

interface ILockingPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);

    function mint(address account) external returns (uint256);

    function burn(uint256 tokenId, address caller) external;

    function logoInfo(uint256 tokenId) external view returns (ILockingLogo.LogoInfos memory);

    function checkYsClaim(uint256 tokenId, address caller) external view;

    function checkOwnership(uint256 _tokenId, address operator) external view;

    function checkOwnerships(uint256[] memory _tokenIds, address operator) external view;

    function checkFullCompliance(uint256 tokenId, address operator) external view;

    function getTokenIdsForWallet(address _wallet) external view returns (uint256[] memory);
}
