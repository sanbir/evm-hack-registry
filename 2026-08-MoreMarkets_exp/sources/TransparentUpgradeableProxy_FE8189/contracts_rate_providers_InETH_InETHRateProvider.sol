// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../InceptionRateProvider.sol";

/// @author The InceptionLRT team
/// @title The InETHRateProvider contract
/// @notice The InceptionRateProvider is used to build a rate provider for inETH LRT.
contract InETHRateProvider is InceptionRateProvider {
    constructor(
        address ratioFeedAddress,
        address assetAddress
    ) payable InceptionRateProvider(ratioFeedAddress, assetAddress) {}

    function inETH() external view returns (address) {
        return _asset;
    }
}
