// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

interface SudoswapLSSVMPairETHInterface {
    function nft() external view returns (address);
    function swapNFTsForToken(uint256[] calldata nftIds, uint256 minExpectedTokenOutput, address payable tokenRecipient) external returns (uint256);
}

interface SudoswapVeryFastRouterInterface {
    struct BuyOrderWithPartialFill {
        address pair;
        bool isERC721;
        uint256[] nftIds;
        uint256 maxInputAmount;
        uint256 ethAmount;
        uint256 expectedSpotPrice;
        uint256[] maxCostPerNumNFTs; // @dev This is zero-indexed, so maxCostPerNumNFTs[x] = max price we're willing to pay to buy x+1 NFTs
    }

    struct SellOrderWithPartialFill {
        address pair;
        bool isETHSell;
        bool isERC721;
        uint256[] nftIds;
        bool doPropertyCheck;
        bytes propertyCheckParams;
        uint128 expectedSpotPrice;
        uint256 minExpectedOutput;
        uint256[] minExpectedOutputPerNumNFTs;
    }

    struct Order {
        BuyOrderWithPartialFill[] buyOrders;
        SellOrderWithPartialFill[] sellOrders;
        address payable tokenRecipient;
        address nftRecipient;
        bool recycleETH;
    }

    /**
     * @dev Performs a batch of sells and buys, avoids performing swaps where the price is beyond
     * Handles selling NFTs for tokens or ETH
     * Handles buying NFTs with tokens or ETH,
     * @param swapOrder The struct containing all the swaps to be executed
     * @return results Indices [0..swapOrder.sellOrders.length-1] contain the actual output amounts of the
     * sell orders, indices [swapOrder.sellOrders.length..swapOrder.sellOrders.length+swapOrder.buyOrders.length-1]
     * contain the actual input amounts of the buy orders.
     */
    function swap(Order calldata swapOrder) external payable returns (uint256[] memory results);
}
