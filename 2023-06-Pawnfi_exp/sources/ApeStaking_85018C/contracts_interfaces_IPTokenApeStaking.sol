// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../interfaces/IApeCoinStaking.sol";

interface IPToken {

    /*** User Interface ***/
    function factory() external view returns(address);
    function nftAddress() external view returns(address);
    function pieceCount() external view returns(uint256);
    function DOMAIN_SEPARATOR() external view returns(bytes32);
    function nonces(address) external view returns(uint256);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function randomTrade(uint256 nftIdCount) external returns(uint256[] memory nftIds);
    function specificTrade(uint256[] memory nftIds) external;
    function deposit(uint256[] memory nftIds) external returns(uint256 tokenAmount);
    function deposit(uint256[] memory nftIds, uint256 blockNumber) external returns(uint256 tokenAmount);
    function withdraw(uint256[] memory nftIds) external returns(uint256 tokenAmount);
    function convert(uint256[] memory nftIds) external;
    function getRandNftCount() external view returns(uint256);
    function getRandNft(uint256 _tokenIndex) external view returns (uint256);
}

interface IPTokenApeStaking is IPToken {
    function depositApeCoin(uint256, IApeCoinStaking.SingleNft[] calldata) external;
    function withdrawApeCoin(IApeCoinStaking.SingleNft[] calldata, address) external;
    function claimApeCoin(uint256[] calldata, address) external;
    function depositBAKC(uint256, IApeCoinStaking.PairNftDepositWithAmount[] calldata) external;
    function withdrawBAKC(IApeCoinStaking.PairNftWithdrawWithAmount[] calldata, address) external;
    function claimBAKC(IApeCoinStaking.PairNft[] calldata, address) external;
    function getNftOwner(uint256) external view returns(address);
}