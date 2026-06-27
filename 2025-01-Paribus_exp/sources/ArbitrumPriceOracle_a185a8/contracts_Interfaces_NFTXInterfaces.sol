// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

interface INFTXVault {
    function assetAddress() external view returns (address);
}

interface INFTXVaultFactory {
    function vault(uint256 vaultId) external view returns (address);
}

interface INFTXMarketplaceZap {
    function WETH() external view returns (address);
    function nftxFactory() external view returns (INFTXVaultFactory);

    function mintAndSell721(uint256 vaultId, uint256[] calldata ids, uint256 minEthOut, address[] calldata path, address to) external;
    function mintAndSell721WETH(uint256 vaultId, uint256[] calldata ids, uint256 minWethOut, address[] calldata path, address to) external;

    function mintAndSell1155(uint256 vaultId, uint256[] calldata ids, uint256[] calldata amounts, uint256 minWethOut, address[] calldata path, address to) external;
    function mintAndSell1155WETH(uint256 vaultId, uint256[] calldata ids, uint256[] calldata amounts, uint256 minWethOut, address[] calldata path, address to) external;
}
