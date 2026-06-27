// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICvxAssetStakingService {
    function depositFeeNoStakingPercentage() external view returns (uint256);
    enum IN_TOKEN_TYPE {
        STK_CVX_ASSET,
        CVX_ASSET,
        ASSET,
        ETH
    }

    enum OUT_TOKEN_TYPE {
        STK_CVX_ASSET,
        CVX_ASSET,
        ASSET
    }
}
