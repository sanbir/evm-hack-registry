// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;
pragma experimental ABIEncoderV2;

interface IOvernightExchange {
    function mint(Exchange.MintParams memory params) external returns (uint256);

    function usdPlus() external view returns (address);

    function usdc() external view returns (address);

}

interface Exchange {
    struct MintParams {
        address asset;
        uint256 amount;
        string referral;
    }
}