// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface INftGateway {
    function mintNft(address, uint[] calldata) external;
    function redeemNft(address, uint[] calldata) external;
    function marketInfo(address) external view returns(address, address, uint, uint, bool);
    function nftOwner(address, address,uint256) external view returns(address);
}