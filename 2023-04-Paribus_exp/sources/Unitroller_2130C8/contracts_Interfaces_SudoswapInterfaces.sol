// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

interface LSSVMPairERC20Interface {
    function nft() external view returns (address);
    function token() external view returns (address);

    function swapNFTsForToken(uint256[] calldata nftIds, uint256 minExpectedTokenOutput, address payable tokenRecipient) external returns (uint256);
}

interface LSSVMRouterInterface {
    struct PairSwapSpecific {
        LSSVMPairERC20Interface pair;
        uint256[] nftIds;
    }

    function swapNFTsForToken(
        PairSwapSpecific[] calldata swapList,
        uint256 minOutput,
        address tokenRecipient,
        uint256 deadline
    ) external returns (uint256);
}
