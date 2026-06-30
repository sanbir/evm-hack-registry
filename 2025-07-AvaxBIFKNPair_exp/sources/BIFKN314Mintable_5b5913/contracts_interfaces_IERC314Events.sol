// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC314Events {
    event AddLiquidity(
        address indexed provider,
        address indexed toAddress,
        uint256 liquidityMinted,
        uint256 nativeAmount,
        uint256 tokenAmount
    );
    event RemoveLiquidity(
        address indexed provider,
        address indexed toAddress,
        uint256 liquidityBurned,
        uint256 nativeAmount,
        uint256 tokenAmount
    );
    event Swap(
        address indexed sender,
        uint256 amountTokenIn,
        uint256 amountNativeIn,
        uint256 amountTokenOut,
        uint256 amountNativeOut,
        bool flashSwap
    );
    event PricesUpdated(
        uint256 tokenPriceInNative,
        uint256 nativePriceInToken,
        uint32 blockTimestampLast
    );
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event FeesCollected(
        address indexed recipient,
        uint256 amountNative,
        uint256 amountToken
    );
    event FeesDistributed(
        address indexed feeTo,
        uint256 nativeAmount,
        uint256 tokenAmount
    );
}
