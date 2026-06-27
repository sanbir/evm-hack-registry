// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Interfaces/NFTXInterfaces.sol";
import "../Interfaces/EIP20NonStandardInterface.sol";

contract NFTXVaultMock is INFTXVault {
    address public assetAddressMock;

    constructor(address _assetAddress) public {
        assetAddressMock = _assetAddress;
    }

    function assetAddress() external view returns (address) {
        return assetAddressMock;
    }
}

contract NFTXVaultFactoryMock is INFTXVaultFactory {
    mapping(uint => INFTXVault) public vaultIdToNFTAsset;

    function vault(uint256 vaultId) external view returns (address) {
        return address(vaultIdToNFTAsset[vaultId]);
    }

    function setNFTAsset(uint vaultId, address nftAssetAddress) public {
        vaultIdToNFTAsset[vaultId] = new NFTXVaultMock(nftAssetAddress);
    }
}

contract NFTXMarketplaceZapMock is INFTXMarketplaceZap {
    address public cryptoPunksAddress;
    NFTXVaultFactoryMock public nftxFactoryMock;

    constructor(address _cryptoPunksAddress, address _nftxFactory) public {
        cryptoPunksAddress = _cryptoPunksAddress;
        nftxFactoryMock = NFTXVaultFactoryMock(_nftxFactory);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function nftxFactory() external view returns (INFTXVaultFactory) {
        return nftxFactoryMock;
    }

    function mintAndSell721(uint256, uint256[] calldata, uint256, address[] calldata, address) external { revert("not implemented"); }
    function mintAndSell1155(uint256, uint256[] calldata, uint256[] calldata, uint256, address[] calldata, address) external { revert("not implemented"); }
    function mintAndSell1155WETH(uint256, uint256[] calldata, uint256[] calldata, uint256, address[] calldata, address) external { revert("not implemented"); }

    function mintAndSell721WETH(uint256 vaultId, uint256[] calldata ids, uint256 minWethOut, address[] calldata path, address to) external {
        address assetOut = path[path.length - 1];

        address nftAssetAddress = INFTXVault(nftxFactoryMock.vault(vaultId)).assetAddress();
        uint256 length = ids.length;

        for (uint256 i; i < length; ++i) {
            _transferFromERC721(nftAssetAddress, ids[i]);
        }

        uint256 extra = ((minWethOut / 21) * 20) / 4; // magic here, do not touch
        EIP20NonStandardInterface(assetOut).transfer(to, minWethOut + extra);
    }

    function _transferFromERC721(address assetAddr, uint256 tokenId) internal {
        bytes memory data;

        if (assetAddr == cryptoPunksAddress) {
            data = abi.encodeWithSignature("buyPunk(uint256)", tokenId);
        } else {
            data = abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", msg.sender, address(this), tokenId);
        }

        (bool success, bytes memory resultData) = address(assetAddr).call(data);
        require(success, string(resultData));
    }
}
